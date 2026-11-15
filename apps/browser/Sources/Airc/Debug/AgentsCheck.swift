// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// mcp1's part of `--script agentspike` (AgentSpikeCheck.swift runs these steps): agents as they ship.
/// - the one-time approval per app: asked, allowed, denied, remembered both ways, unanswered, an app identified by its
///   code signature (an Apple program between Airc and the helper), a removed app's connection ended and asked again;
/// - logged-in sessions: the person signs in to a fixture site in their window; an agent window in that profile is
///   already signed in, one in another profile isn't;
/// - passwords: fill only (fill_saved_login fills the page; no tool output carries the password, the session cookie or
///   a one-time code; read_page masks password-like fields);
/// - the one-click setup on a scratch home (Claude Desktop's config merged with a backup, the Claude Code command run by
///   a stand-in CLI, the JSON snippet) and the stable helper link;
/// - "Let AI apps use Airc" off: no socket, the helper refused; idle CPU and memory with the server on and no client;
/// - Settings › Agents and the approval panel as pictures (agents-settings.png, agents-approval.png).
extension AgentSpike {
    // MARK: Helpers

    func poll(_ condition: @escaping () -> Bool, timeout: Double, _ then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func tick() {
            if condition() { return then(true) }
            if Date() > deadline { return then(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: tick)
        }
        tick()
    }

    func savePNG(_ rep: NSBitmapImageRep?, _ name: String) {
        guard let data = rep?.representation(using: .png, properties: [:]) else { return note("no picture for \(name)") }
        try? data.write(to: runner.dir.appendingPathComponent("\(name).png"))
    }

    struct PanelSeen { var title = ""; var key = false; var appActive = false; var onScreen = false }

    /// Starts a helper, answers the approval panel if one shows (after 0.3 s, through the panel's own button action),
    /// and reports whether the MCP handshake went through and whether Airc asked.
    func connect(_ c: SpikeMCPClient, answer: AgentDecision?, shot: String? = nil,
                 _ done: @escaping (_ ok: Bool, _ asked: PanelSeen?) -> Void) {
        var finished = false
        var seen: PanelSeen?
        func end(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            done(ok, seen)
        }
        c.onExit = { end(false) }
        guard c.start() else { return end(false) }
        c.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "agents-check", "version": "1"]],
                  timeout: 20) { m in
            let ok = (m["result"] as? [String: Any])?["protocolVersion"] != nil
            if ok { c.send(["jsonrpc": "2.0", "method": "notifications/initialized"]) }
            end(ok)
        }
        poll({ finished || AgentCenter.shared.approvals.shown != nil }, timeout: 6) { _ in
            guard !finished, let panel = AgentCenter.shared.approvals.shown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                seen = PanelSeen(title: panel.title, key: panel.isKeyWindow, appActive: NSApp.isActive,
                                 onScreen: panel.isVisible && NSScreen.screens.contains { $0.frame.intersects(panel.frame) })
                if let shot { self.savePNG(panel.picture(), shot) }
                if let answer { panel.answer(answer) }
            }
        }
    }

    // MARK: First connection (setUp)

    func firstConnection(_ done: @escaping () -> Void) {
        client = helper("Agent")
        connect(client, answer: .allow, shot: "agents-approval") { ok, asked in
            self.check(asked?.title == "Allow agentspike-check to use Airc?",
                       "the first connection from a new app asks once (“\(asked?.title ?? "no panel")”)")
            self.check(asked.map { !$0.key && !$0.appActive && $0.onScreen } ?? false,
                       "the question shows without taking focus (panel key \(asked?.key ?? false), Airc active \(asked?.appActive ?? false))")
            self.check(ok, "airc-mcp connects with --profile Agent once allowed")
            self.check(AgentCenter.shared.client("airc|name:agentspike-check")?.allowed == true, "the answer is remembered for the app")
            var st = stat()
            let path = AppPaths.dataDirectory.appendingPathComponent("Agents.json").path
            self.check(stat(path, &st) == 0 && st.st_mode & 0o777 == 0o600, "Agents.json is 0600")
            done()
        }
    }

    // MARK: Logged-in sessions and passwords

    static let loginPage = """
    <!doctype html><html><head><title>Sign in</title><style>body{margin:0;font:16px -apple-system,sans-serif}
    form{margin:40px 60px}input,button{display:block;box-sizing:border-box;width:300px;height:36px;margin:12px 0}</style></head><body>
    <form id="login" method="post" action="/login">
    <input id="u" name="username" autocomplete="username" placeholder="Email">
    <input id="p" name="password" type="password" autocomplete="current-password" placeholder="Password">
    <button id="go">Sign in</button></form>
    <form id="extra" onsubmit="return false">
    <input id="otp" name="otp_code" value="424242" placeholder="One-time code">
    <input id="reveal" name="password_shown" value="REVEAL" aria-label="Password (shown)">
    </form></body></html>
    """

    /// The fixture site's session: POST /login sets an HttpOnly cookie; /account greets whoever carries it.
    func sessionSite(_ r: LocalPageServer.Request) -> LocalPageServer.Page? {
        if let page = demoPages?(r) { return page }
        switch (r.method, r.path) {
        case ("GET", "/login"):
            return LocalPageServer.Page(body: Self.loginPage.replacingOccurrences(of: "REVEAL", with: loginPassword))
        case ("POST", "/login"):
            return LocalPageServer.Page(status: "303 See Other",
                                        headers: ["Location": "/account", "Set-Cookie": "sid=\(sessionSecret); Path=/; HttpOnly; SameSite=Lax"], body: "")
        case ("GET", "/account"):
            let signedIn = (r.headers["cookie"] ?? "").contains("sid=\(sessionSecret)")
            return LocalPageServer.Page(body: signedIn
                ? "<!doctype html><title>Account</title><h1>Signed in as Ada Example</h1><p>Orders: 3</p>"
                : "<!doctype html><title>Account</title><h1>Not signed in</h1><p><a href=\"/login\">Sign in</a></p>")
        default:
            return nil
        }
    }

    func personPage() -> EngineTab? { runner.c.shownTabID.flatMap { runner.c.engineTab(for: $0) } }

    /// The person signs in in their own window (their default profile): typed into the form, submitted.
    func personSignsIn(_ done: @escaping (Bool) -> Void) {
        let c = runner.c!
        guard let t = try? c.store.openTab(url: "\(base)/login", inSpace: c.currentSpaceID, title: "Sign in") else { return done(false) }
        c.reloadAll(animated: false)
        c.show(t.id, focus: false)
        poll({ self.personPage()?.title == "Sign in" && self.personPage()?.isLoading == false }, timeout: 10) { loaded in
            guard loaded, let page = self.personPage() else { return done(false) }
            #if canImport(AircCore)
            if let chromium = self.app.engine as? ChromiumEngine {
                // Typed (Input.insertText), as a person types: Chromium then offers to save the login.
                func typeInto(_ id: String, _ text: String, _ next: @escaping () -> Void) {
                    chromium.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('\(id)').focus()", "userGesture": true], in: page) { _, _ in
                        chromium.devToolsCall("Input.insertText", params: ["text": text], in: page) { _, _ in next() }
                    }
                }
                return typeInto("u", "ada@example.test") {
                    typeInto("p", self.loginPassword) {
                        chromium.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('go').click()", "userGesture": true], in: page) { _, _ in
                            self.poll({ self.personPage()?.title == "Account" }, timeout: 10) { ok in
                                // Saved, as the person would in the "Save password?" prompt.
                                self.poll({ chromium.passwordPrompt(for: page)?["state"] as? String == "save" }, timeout: 6) { offered in
                                    self.check(offered, "the person's sign-in is offered for saving (Chromium)")
                                    if offered { chromium.resolvePasswordPrompt(in: page, action: "save") }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { done(ok) }
                                }
                            }
                        }
                    }
                }
            }
            #endif
            page.evaluate("document.getElementById('u').value='ada@example.test';document.getElementById('p').value='\(self.loginPassword)';document.getElementById('login').submit();true") { _ in
                self.poll({ self.personPage()?.title == "Account" }, timeout: 10) { done($0) }
            }
        }
    }

    func loggedInChecks(_ done: @escaping () -> Void) {
        personSignsIn { signedIn in
            self.check(signedIn, "the person signs in to the fixture site in their own window")
            let c = self.runner.c!
            self.personState = (self.app.controllers.count, c.shownTabID, self.personPage()?.url?.absoluteString)
            let defaultName = self.app.store.defaultProfile.name
            let d = self.helper(defaultName)
            self.extra.append(d)
            var said = ""   // every word an agent got back in this step
            func call(_ tool: String, _ args: [String: Any] = [:], _ then: @escaping ([String: Any]) -> Void) {
                d.call(tool, args) { r, _ in said += SpikeMCPClient.text(r); then(r) }
            }
            self.connect(d, answer: nil) { ok, asked in
                self.check(ok && asked == nil, "the allowed app connects again without being asked (remembered)")
                call("open_window", ["url": "\(self.base)/account"]) { r in
                    let personalWindow = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                    call("read_page") { r in
                        let text = SpikeMCPClient.text(r)
                        self.check(text.contains("Signed in as Ada Example"),
                                   "an agent window in the person's profile is already signed in (logged-in session)")
                        // The same site in another profile: no session there.
                        self.client.call("open_window", ["url": "\(self.base)/account"]) { r, _ in
                            let other = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                            self.client.call("read_page", ["window": other]) { r, _ in
                                said += SpikeMCPClient.text(r)
                                self.check(SpikeMCPClient.text(r).contains("Not signed in"), "an agent window in another profile isn't signed in there")
                                self.client.call("close_window", ["window": other]) { _, _ in
                                    self.passwordChecks(d, personalWindow, call: call) {
                                        self.check(!said.contains(self.sessionSecret) && !said.contains(self.loginPassword) && !said.contains("424242"),
                                                   "no tool output in this step carries the session cookie, the password or the one-time code (\(said.count) characters)")
                                        call("close_window", ["window": personalWindow]) { _ in
                                            d.stop()
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done() }
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

    func passwordChecks(_ d: SpikeMCPClient, _ window: Int, call: @escaping (String, [String: Any], @escaping ([String: Any]) -> Void) -> Void,
                        _ done: @escaping () -> Void) {
        call("navigate", ["url": "\(base)/login", "window": window]) { _ in
            call("read_page", ["mode": "outline", "window": window]) { r in
                let out = SpikeMCPClient.text(r)
                self.check(out.contains("(hidden)") && !out.contains(self.loginPassword) && !out.contains("424242"),
                           "read_page masks the password field, a shown-password field and a one-time code")
                call("find_element", ["text": "Email", "window": window]) { r in
                    let m = ((SpikeMCPClient.text(r).components(separatedBy: "\n").compactMap { line -> [[String: Any]]? in
                        guard line.hasPrefix("[") else { return nil }
                        return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]]
                    }).first ?? []).first
                    let x = (m?["x"] as? Int) ?? 210, y = (m?["y"] as? Int) ?? 58
                    call("left_click", ["coordinate": [x, y], "window": window]) { _ in
                        call("fill_saved_login", ["window": window]) { r in
                            let text = SpikeMCPClient.text(r)
                            if self.engine == "chromium" {
                                self.check(!SpikeMCPClient.isError(r) && SpikeMCPClient.json(r)["username"] as? String == "ada@example.test",
                                           "fill_saved_login fills the saved login (\(text.prefix(120)))")
                                guard let w = AgentCenter.shared.windows[window], let tab = w.activeTab else { return done() }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    w.driver.evaluate(tab, "(function(){return JSON.stringify({ok:document.getElementById('p').value===\(AgentPageScripts.jsString(self.loginPassword)),u:document.getElementById('u').value})})()") { v in
                                        let s = agentJSON(v) ?? [:]
                                        self.check(s["ok"] as? Bool == true && s["u"] as? String == "ada@example.test",
                                                   "the page's form holds the saved login after the fill (checked in the page, never returned)")
                                        done()
                                    }
                                }
                            } else {
                                self.check(SpikeMCPClient.isError(r) && text.contains("Chromium"), "fill_saved_login says WebKit has no saved logins")
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    func personWindowUntouched() {
        guard let before = personState else { return check(false, "the person's window state was recorded") }
        let now = (app.controllers.count, runner.c.shownTabID, personPage()?.url?.absoluteString)
        check(now.0 == before.tabs && now.1 == before.shown && now.2 == before.url,
              "the person's windows are untouched by agents (\(now.0) windows, the same tab and address)")
    }

    // MARK: Approval: deny, remembered, an Apple program, removed, unanswered

    func approvalChecks(_ done: @escaping () -> Void) {
        let deny = helper("Agent", client: "deny-check")
        connect(deny, answer: .deny) { ok, asked in
            self.check(!ok && asked != nil && deny.exitCode == 77 && deny.stderrText.contains("chose not to let"),
                       "Don't Allow refuses the app (exit \(deny.exitCode ?? -1))")
            let again = self.helper("Agent", client: "deny-check")
            let t = CFAbsoluteTimeGetCurrent()
            self.connect(again, answer: nil) { ok, asked in
                self.check(!ok && asked == nil && again.exitCode == 77 && CFAbsoluteTimeGetCurrent() - t < 3,
                           "a refused app is refused again without asking (remembered)")
                self.signedClient(done)
            }
        }
    }

    /// An app started through an Apple program: identified by its code signature, removed, asked again.
    func signedClient(_ done: @escaping () -> Void) {
        let timed = helper("Agent", client: "time-check", via: "/usr/bin/time")
        extra.append(timed)
        connect(timed, answer: .allow) { ok, asked in
            let rec = AgentCenter.shared.settings.clients.first { $0.key.hasPrefix("apple:com.apple.time") }
            self.check(ok && asked != nil && rec != nil,
                       "a client under an Apple program is identified by its signature (\(rec?.key ?? "none"), \(rec?.detail ?? ""))")
            timed.call("open_window", ["url": "\(self.base)/second.html"]) { r, _ in
                let id = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                guard let key = rec?.key else { return done() }
                AgentCenter.shared.removeClient(key)
                self.poll({ timed.exitCode != nil }, timeout: 4) { ended in
                    self.check(ended && AgentCenter.shared.windows[id] == nil && AgentCenter.shared.client(key) == nil,
                               "Remove ends the app's connection, closes its windows and forgets it (exit \(timed.exitCode ?? -1))")
                    let back = self.helper("Agent", client: "time-check", via: "/usr/bin/time")
                    self.connect(back, answer: .deny) { ok, asked in
                        self.check(!ok && asked != nil, "a removed app is asked again")
                        self.unanswered(done)
                    }
                }
            }
        }
    }

    func unanswered(_ done: @escaping () -> Void) {
        AgentCenter.shared.approvals.timeout = 1.5
        let silent = helper("Agent", client: "silent-check")
        connect(silent, answer: nil) { ok, asked in
            AgentCenter.shared.approvals.timeout = 120
            self.check(!ok && asked != nil && silent.stderrText.contains("no answer") && AgentCenter.shared.client("airc|name:silent-check") == nil,
                       "an unanswered question refuses the connection and remembers nothing")
            self.check(AgentCenter.shared.approvals.waitingCount == 0, "no question left open")
            done()
        }
    }

    // MARK: One-click setup

    func configChecks(_ done: @escaping () -> Void) {
        let fm = FileManager.default
        let home = runner.dir.appendingPathComponent("scratch-home")
        try? fm.removeItem(at: home)
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        AgentSetup.refreshStableHelper()
        let link = AgentSetup.stableHelper()
        let dest = try? fm.destinationOfSymbolicLink(atPath: link.path)
        check(dest == AgentSetup.bundledHelper.path && fm.isExecutableFile(atPath: link.path) && AgentSetup.helperPath == link.path,
              "configs use a stable helper link that points into the app bundle (\(dest ?? "none"))")
        let file = AgentSetup.claudeDesktopConfig(home: home)
        func read() -> [String: Any] { (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
        func backups() -> [String] { ((try? fm.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)) ?? []).filter { $0.contains(".airc-backup-") } }
        // No file yet.
        var r = AgentSetup.addToClaudeDesktop(home: home)
        var airc = (read()["mcpServers"] as? [String: Any])?["airc"] as? [String: Any]
        check(r == .added(backup: nil) && airc?["command"] as? String == link.path && (airc?["args"] as? [String])?.contains("--data-dir") == true,
              "Add to Claude Desktop writes a new config (\(r.message))")
        // A config with other things in it: merged, the old one kept.
        let original = Data("{\"globalShortcut\":\"Cmd+Shift+Space\",\"mcpServers\":{\"other\":{\"command\":\"/bin/echo\",\"args\":[\"hi\"]}}}".utf8)
        try? original.write(to: file)
        r = AgentSetup.addToClaudeDesktop(home: home, now: Date(timeIntervalSince1970: 1_800_000_000))
        let merged = read()
        let servers = merged["mcpServers"] as? [String: Any]
        airc = servers?["airc"] as? [String: Any]
        let backup: String? = { if case .added(let b) = r { return b }; return nil }()
        check(backup != nil && (try? Data(contentsOf: URL(fileURLWithPath: backup!))) == original
              && servers?["other"] != nil && merged["globalShortcut"] as? String == "Cmd+Shift+Space" && airc != nil,
              "an existing config is merged (other servers and settings kept) with a backup (\(backups()))")
        r = AgentSetup.addToClaudeDesktop(home: home)
        check(r == .alreadyThere && backups().count == 1, "adding again changes nothing (\(r.message))")
        // A broken file is left alone.
        let broken = Data("{ not json".utf8)
        try? broken.write(to: file)
        r = AgentSetup.addToClaudeDesktop(home: home)
        check({ if case .failed = r { return true }; return false }() && (try? Data(contentsOf: file)) == broken,
              "a config that isn't JSON is left untouched")
        // Claude Code: the command, and a stand-in CLI that records what it was asked.
        let cmd = AgentSetup.claudeCodeCommand
        check(cmd.hasPrefix("claude mcp add --scope user airc -- ") && cmd.contains(AgentSetup.shellQuote(link.path)),
              "the Claude Code command names the stable helper (\(cmd))")
        check(AgentSetup.findClaudeCLI(home: home) == nil, "no Claude Code CLI in the scratch home")
        let bin = home.appendingPathComponent(".local/bin")
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("claude")
        let record = home.appendingPathComponent("claude-args.txt")
        try? "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(record.path)'\necho 'Added stdio MCP server airc'\n".write(to: cli, atomically: true, encoding: .utf8)
        _ = chmod(cli.path, 0o755)
        check(AgentSetup.findClaudeCLI(home: home) == cli, "Claude Code's CLI is found where its installer puts it")
        let json = (try? JSONSerialization.jsonObject(with: Data(AgentSetup.otherAppsJSON.utf8)) as? [String: Any]) ?? [:]
        check(((json["mcpServers"] as? [String: Any])?["airc"] as? [String: Any])?["command"] as? String == link.path,
              "the Other apps snippet is valid JSON naming the helper")
        AgentSetup.addToClaudeCode(cli: cli, home: home) { outcome in
            let args = (try? String(contentsOf: record, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            self.check(outcome == .added(backup: nil) && Array(args.prefix(6)) == ["mcp", "add", "--scope", "user", "airc", "--"] && args.dropFirst(6).first == link.path,
                       "Add to Claude Code runs `claude mcp add --scope user airc -- <helper>` (\(args.prefix(8).joined(separator: " ")))")
            // The written config works: its command and args, run as Claude Desktop would.
            AgentCenter.shared.approvals.automatic = true
            let desktop = SpikeMCPClient(helper: link.path, args: (airc?["args"] as? [String]) ?? [])
            self.connect(desktop, answer: nil) { ok, _ in
                AgentCenter.shared.approvals.automatic = nil
                self.check(ok, "the command written to Claude Desktop's config connects to Airc")
                desktop.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
            }
        }
    }

    // MARK: Off, idle cost with the server on

    func offAndIdleServer(_ done: @escaping () -> Void) {
        for c in extra { c.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.check(AgentCenter.shared.connectedCount == 0 && AgentCenter.shared.windows.isEmpty && AgentCenter.shared.isServing,
                       "idle: server on, no client, no agent window")
            let me = getpid()
            let a = self.processes().first { $0.pid == me }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                let b = self.processes().first { $0.pid == me }
                let cpu = ((b?.cpuSeconds ?? 0) - (a?.cpuSeconds ?? 0)) / 10 * 100
                self.measure("idle_server_on_cpu_percent", Self.r1(cpu))
                self.measure("idle_server_on_app_rss_mb", Self.r1(Double(b?.rssKB ?? 0) / 1024))
                // Off: the socket goes and the helper is refused at once.
                AgentCenter.shared.setEnabled(false)
                self.check(!AgentCenter.shared.isServing && !FileManager.default.fileExists(atPath: AgentCenter.shared.socketPath),
                           "Let AI apps use Airc off: the socket is gone")
                let refused = self.helper("Agent")
                self.connect(refused, answer: nil) { ok, _ in
                    self.check(!ok && refused.exitCode == 69 && refused.stderrText.contains("Settings › Agents"),
                               "with agents off the helper is refused and says where to turn them on (exit \(refused.exitCode ?? -1))")
                    let c = self.processes().first { $0.pid == me }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        let d = self.processes().first { $0.pid == me }
                        self.measure("idle_server_off_cpu_percent", Self.r1(((d?.cpuSeconds ?? 0) - (c?.cpuSeconds ?? 0)) / 10 * 100))
                        self.measure("idle_server_off_app_rss_mb", Self.r1(Double(d?.rssKB ?? 0) / 1024))
                        AgentCenter.shared.setEnabled(true)
                        self.check(AgentCenter.shared.isServing, "turned back on, the server listens again")
                        let text = (try? String(contentsOf: AgentCenter.shared.logFile, encoding: .utf8)) ?? ""
                        self.check(!text.contains(self.loginPassword) && !text.contains(self.sessionSecret) && !text.contains("Ada Example"),
                                   "the log has no password, session cookie or signed-in page text")
                        done()
                    }
                }
            }
        }
    }

    // MARK: Settings › Agents

    func settingsShot(_ done: @escaping () -> Void) {
        app.showSettings(page: .agents)
        guard let w = app.settingsWindow?.window else { check(false, "Settings › Agents opens"); return done() }
        w.setContentSize(NSSize(width: 780, height: 1180))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.check(self.app.settingsWindow?.model.page == .agents && !NSApp.isActive, "Settings › Agents opens (without activating Airc in a scripted run)")
            // The marketing shots' renderer: SwiftUI's scroll content doesn't come out of cacheDisplay.
            if let img = self.runner.mkContentImage(w), let tiff = img.tiffRepresentation {
                self.savePNG(NSBitmapImageRep(data: tiff), "agents-settings")
            }
            w.close()
            done()
        }
    }
}
#endif
