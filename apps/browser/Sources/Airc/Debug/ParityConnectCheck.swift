// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityconnect` (Agent/AgentsConnect.swift, artifacts/agentview/REPORT.md "Connect Claude"): every way to
/// connect Claude leads to Settings › Agents with setup first, proven with the build Mac's UI driver (real keys and
/// clicks; `AIRC_UI_DEDICATED_SESSION=1 AIRC_REAL_KEYS=1 AIRC_LA_AS_OWNER=1`, else FAIL-ENV and posted):
/// - ⌘T and "claude", "mcp", "agent", "ai app", "connect" each offer "Connect Claude and other AI apps…"; for "mcp" it's
///   the top row, and Return opens Settings › Agents with Set up first;
/// - Help › Use Airc with Claude… (a real click on Help's title, its name typed in Help's search, ↓, Return);
/// - the sidebar footer's "+" menu › Connect Claude… (a real click on "+", ↓ to the item, Return), only while no app has
///   ever connected;
/// - Settings › Agents › Add to Claude Desktop (a real click; the question's Add, a real click) writes the config into a
///   scratch home and says what's next; the account's real Claude config is untouched;
/// - the Access line says what's true: none yet, "<app> connected now", "<app> allowed".
extension SnapshotRunner {
    func parityConnectScenario() {
        let k = ConnectCheck(runner: self)
        step { done in k.setUp(done) }
        step { done in k.commandBar(done) }
        step { done in k.setUpFirst(done) }
        step { done in k.helpMenu(done) }
        step { done in k.plusMenu(done) }
        step { done in k.afterConnecting(done) }
        run { k.finish() }
    }
}

final class ConnectCheck {
    unowned let runner: SnapshotRunner
    var app: AppDelegate { runner.app! }
    var c: WindowController { runner.c }
    var engine = "?"
    var real = false
    var sandbox: URL!
    var realConfigBefore: Data?
    var menus: [NSMenu] = []
    var menuObserver: NSObjectProtocol?

    init(runner: SnapshotRunner) { self.runner = runner }

    func note(_ s: String) { runner.note(s) }
    func check(_ ok: Bool, _ what: String) { note((ok ? "PASS " : "FAIL ") + "parityconnect \(engine): " + what) }
    func after(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }
    var settingsWindow: NSWindow? { app.settingsWindow?.window }
    var onAgents: Bool { app.settingsWindow?.model.page == .agents && settingsWindow?.isVisible == true }

    func setUp(_ done: @escaping () -> Void) {
        engine = app.engine is WebKitEngine ? "webkit" : "chromium"
        let env = ProcessInfo.processInfo.environment
        real = UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
        note("parityconnect \(engine): input \(real ? "real (UI driver)" : "posted")")
        sandbox = runner.dir.appendingPathComponent("connect-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: AgentSetup.claudeDesktopConfig(home: sandbox).deletingLastPathComponent(), withIntermediateDirectories: true)
        realConfigBefore = try? Data(contentsOf: AgentSetup.claudeDesktopConfig(home: FileManager.default.homeDirectoryForCurrentUser))
        AgentSetup.homeOverride = sandbox
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] n in
            if let m = n.object as? NSMenu { self?.menus.append(m) }
        }
        AgentCenter.shared.app = app
        AgentCenter.shared.enableForCheck(grants: [], http: false)
        AgentCenter.shared.approvals.automatic = true
        check(AgentsConnect.neverConnected && AgentCenter.shared.accessStatus == "On. No app has connected yet.",
              "a fresh Airc: no app has connected, and Access says so (\(AgentCenter.shared.accessStatus))")
        front(c.window) { _ in done() }
    }

    func front(_ w: NSWindow, _ then: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        runner.waitUntil({ NSApp.isActive && w.isKeyWindow }, timeout: 5) { then(NSApp.isActive && w.isKeyWindow) }
    }

    func closeSettings(_ then: @escaping () -> Void) {
        settingsWindow?.close()
        AgentsSettingsModel.shared.setUpFirst = false
        after(0.4) { self.front(self.c.window) { _ in then() } }
    }

    // MARK: Real input

    func key(_ combo: String, _ then: @escaping (Bool) -> Void) {
        guard real else { return then(false) }
        UIDriverClient.run(["--key", combo, "--pid", "\(getpid())"]) { ok, out in
            if !ok { self.note("FAIL-ENV parityconnect \(self.engine) [real key] \(combo): \(out)") }
            then(ok)
        }
    }

    func type(_ text: String, _ then: @escaping (Bool) -> Void) {
        guard real, let keys = UIDriverClient.keys(typing: text) else { return then(false) }
        UIDriverClient.press(keys, pid: getpid()) { ok, _ in then(ok) }
    }

    func click(at p: NSPoint, in w: NSWindow, _ then: @escaping (Bool) -> Void) {
        guard real, let primary = NSScreen.screens.first else { return then(false) }
        let g = w.convertPoint(toScreen: p)
        UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
            if !ok { self.note("FAIL-ENV parityconnect \(self.engine) [real click]: \(out)") }
            self.after(0.3) { then(ok) }
        }
    }

    /// One real key from a background thread while a menu tracks (its own run loop on the main thread).
    static func syncKey(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: UIDriverClient.path)
        p.arguments = ["--json"] + args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CFFIXED_USER_HOME")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.15)
        return p.terminationStatus == 0 && out.replacingOccurrences(of: " ", with: "").contains("\"ok\":true")
    }

    static func onMain<T>(_ body: @escaping () -> T) -> T? {
        var value: T?
        let sem = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { value = body(); sem.signal() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return sem.wait(timeout: .now() + 2) == .success ? value : nil
    }

    /// In a tracking menu: real ↓ until an item titled `title` is highlighted, then Return. `start` runs first (keys
    /// that open the menu). Answers on main: picked, and a trace.
    func pickInMenu(_ title: String, start: [[String]], _ done: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var trace: [String] = []
            for args in start { trace.append("\(args.joined(separator: " ")) \(Self.syncKey(args))") }
            // Keys only once a menu tracks (its items come in as tracking begins).
            for _ in 0..<30 where (Self.onMain { self.menus.isEmpty } ?? true) { Thread.sleep(forTimeInterval: 0.1) }
            let tracked = Self.onMain { self.menus.map { $0.title.isEmpty ? "(untitled)" : $0.title } } ?? []
            trace.append("tracking \(tracked)")
            Thread.sleep(forTimeInterval: 0.5)
            var picked = false
            for _ in 0..<16 {
                let current = Self.onMain { () -> String? in
                    self.menus.reversed().compactMap { $0.highlightedItem?.title }.first
                } ?? nil
                trace.append("highlighted \(current ?? "none")")
                if current == title {
                    picked = Self.syncKey(["--key", "return"])
                    break
                }
                if !Self.syncKey(["--key", "down"]) { break }
            }
            if !picked { _ = Self.syncKey(["--key", "esc", "--repeat", "3"]) }
            DispatchQueue.main.async { done(picked, trace.suffix(6).joined(separator: "; ")) }
        }
    }

    // MARK: Cases

    func commandBar(_ done: @escaping () -> Void) {
        // The real pointer off the bar's rows (they select on hover): the sidebar footer's empty middle.
        if real {
            let f = c.sidebar.footer
            UIDriverClient.move(f.convert(NSPoint(x: f.bounds.midX + 30, y: f.bounds.midY), to: nil), in: c.window) { _, _ in }
        }
        let words = ["claude", "agent", "ai app", "connect", "mcp"]
        func next(_ rest: ArraySlice<String>) {
            guard let word = rest.first else { return done() }
            key("cmd+t") { _ in
                self.after(0.6) {
                    if !self.real { self.c.openCommandBar(mode: .newTab); self.c.commandBar?.type(word) }
                    self.type(word) { _ in
                        self.after(0.9) {
                            let rows = self.c.commandBar?.results.map(\.title) ?? []
                            let how = self.real ? "real keys" : "posted"
                            self.check(rows.contains(AgentsConnect.commandTitle), "[\(how)] ⌘T “\(word)” offers \(AgentsConnect.commandTitle) (\(rows.prefix(4)))")
                            guard word == "mcp" else {
                                if self.real { self.key("esc") { _ in self.key("esc") { _ in self.after(0.4) { next(rest.dropFirst()) } } } }
                                else { self.c.closeCommandBar(); next(rest.dropFirst()) }
                                return
                            }
                            self.check(rows.first == AgentsConnect.commandTitle && self.c.commandBar?.selected == 0,
                                       "[\(how)] ⌘T “mcp”: it's the top row, selected")
                            AgentsSettingsModel.shared.setUpFirst = false
                            let open = { self.runner.waitUntil({ self.onAgents }, timeout: 4) {
                                self.check(self.onAgents && AgentsSettingsModel.shared.setUpFirst, "[\(how)] Return opens Settings › Agents with Set up first")
                                next(rest.dropFirst())
                            } }
                            if self.real { self.key("return") { _ in open() } }
                            else { self.c.closeCommandBar(); AgentsConnect.open(app: self.app, from: "command-bar"); open() }
                        }
                    }
                }
            }
        }
        next(words[...])
    }

    /// Set up is on top and its first step works: a real click on Add to Claude Desktop, then on the question's Add.
    func setUpFirst(_ done: @escaping () -> Void) {
        guard let w = settingsWindow, let content = w.contentView else { check(false, "Settings is open"); return done() }
        front(w) { key in
            content.layoutSubtreeIfNeeded()
            guard let r = TestAnchors.frame("agents-add-claude-desktop", in: content) else {
                self.check(false, "Add to Claude Desktop is on screen"); return self.closeSettings(done)
            }
            self.check(r.minY < 560, "Connect Claude is on top: Add to Claude Desktop at \(Int(r.minY)) pt from the top")
            let p = NSPoint(x: r.midX, y: content.isFlipped ? r.midY : content.bounds.height - r.midY)
            let press = { (then: @escaping () -> Void) in
                if self.real && key { self.click(at: content.convert(p, to: nil), in: w) { _ in then() } }
                else { self.note("FAIL-ENV parityconnect \(self.engine): Add to Claude Desktop posted"); AgentsSettingsModel.shared.addToClaudeDesktop(window: w); then() }
            }
            press {
                self.runner.waitUntil({ w.attachedSheet != nil }, timeout: 3) {
                    guard let sheet = w.attachedSheet, let add = self.descendants(sheet.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Add" }) else {
                        self.check(false, "Add to Claude Desktop asks first"); return self.closeSettings(done)
                    }
                    self.check(true, "Add to Claude Desktop asks first")
                    let after = {
                        self.runner.waitUntil({ AgentsSettingsModel.shared.setupMessage?.contains("Restart") == true }, timeout: 3) {
                            let msg = AgentsSettingsModel.shared.setupMessage ?? ""
                            let config = AgentSetup.claudeDesktopConfig(home: self.sandbox)
                            let root = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                            self.check((root?["mcpServers"] as? [String: Any])?["airc"] != nil, "it writes mcpServers.airc (into the scratch home)")
                            self.check(msg.contains("Restart Claude Desktop, then ask it to open a page in Airc."), "it says what's next (\(msg))")
                            self.check((try? Data(contentsOf: AgentSetup.claudeDesktopConfig(home: FileManager.default.homeDirectoryForCurrentUser))) == self.realConfigBefore,
                                       "the account's real Claude config is untouched")
                            self.closeSettings(done)
                        }
                    }
                    if self.real && key { self.click(at: add.convert(NSPoint(x: add.bounds.midX, y: add.bounds.midY), to: nil), in: sheet) { _ in after() } }
                    else { add.performClick(nil); after() }
                }
            }
        }
    }

    /// Help › Use Airc with Claude… with real input, as easelall opens File: Help's title frame from this app's own
    /// accessibility tree (no trust needed), a real driver click on it, then the item's name typed into Help's search
    /// field, ↓ and Return. Tracking is posted with the main menu as its object. The pointer goes back over the window afterwards.
    func helpMenu(_ done: @escaping () -> Void) {
        AgentsSettingsModel.shared.setUpFirst = false
        guard let help = NSApp.helpMenu, let index = help.items.firstIndex(where: { $0.title == AgentsConnect.helpTitle }) else {
            check(false, "Help has \(AgentsConnect.helpTitle)"); return done()
        }
        let title = SnapshotRunner.easelAllMenuBarTitleCenter("Help")
        guard real, let pt = title else {
            note("FAIL-ENV parityconnect \(engine): Help menu posted (\(real ? "no frame for Help's title" : "no UI driver"))")
            help.performActionForItem(at: index)
            return verifyOpened("[posted] Help › \(AgentsConnect.helpTitle)", done)
        }
        var opened = false
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            if let m = n.object as? NSMenu, m === help || m === NSApp.mainMenu { opened = true }
        }
        // Help opens with macOS's search field focused (it takes ↓ and ↑): type the item's name there, then ↓ to the
        // match and Return. Layout-aware keys (UIDriverClient.keys); success is Settings › Agents opening.
        let typed = UIDriverClient.keys(typing: "Use Airc with Claude") ?? []
        front(c.window) { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                var trace = ["Help at \(Int(pt.x)),\(Int(pt.y))"]
                trace.append("click \(Self.syncKey(["--click", "\(Int(pt.x))", "\(Int(pt.y))"]))")
                Thread.sleep(forTimeInterval: 0.8)
                trace.append("menu opened \(opened)")
                if opened {
                    let ok = typed.allSatisfy { Self.syncKey(["--key", $0]) }
                    trace.append("typed \(ok) (\(typed.count) keys)")
                    Thread.sleep(forTimeInterval: 1.2)
                    trace.append("↓ \(Self.syncKey(["--key", "down"]))")
                    Thread.sleep(forTimeInterval: 0.4)
                    trace.append("⏎ \(Self.syncKey(["--key", "return"]))")
                }
                Thread.sleep(forTimeInterval: 0.8)
                let picked = Self.onMain { self.onAgents } ?? false
                if !picked { _ = Self.syncKey(["--key", "esc", "--repeat", "2"]) }
                // The pointer off the menu bar (it disturbs later presses there): over the window again.
                if let park = Self.onMain({ () -> CGPoint? in
                    guard let primary = NSScreen.screens.first else { return nil }
                    let f = self.c.window.frame
                    return CGPoint(x: f.midX, y: primary.frame.maxY - f.midY)
                }) ?? nil {
                    _ = Self.syncKey(["--move", "\(Int(park.x))", "\(Int(park.y))"])
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.removeObserver(token)
                    self.note("parityconnect \(self.engine): Help menu \(trace.joined(separator: " "))")
                    if !picked {
                        self.note("FAIL-ENV parityconnect \(self.engine): Help's search didn't run the item after a real click on Help (opened \(opened)); posted")
                        help.performActionForItem(at: index)
                    }
                    self.verifyOpened("[\(picked ? "real click and keys" : "posted")] Help › \(AgentsConnect.helpTitle)", done)
                }
            }
        }
    }

    func plusMenu(_ done: @escaping () -> Void) {
        AgentsSettingsModel.shared.setUpFirst = false
        let titles = c.plusMenu().items.map(\.title)
        check(titles.last == AgentsConnect.plusTitle, "the \"+\" menu ends with \(AgentsConnect.plusTitle) while no app has connected (\(titles.suffix(3)))")
        guard real, let plus = descendants(c.sidebar.footer).first(where: { $0.toolTip == "New…" }) else {
            note("FAIL-ENV parityconnect \(engine): \"+\" menu posted")
            let m = c.plusMenu()
            m.performActionForItem(at: m.items.count - 1)
            return verifyOpened("[posted] + › \(AgentsConnect.plusTitle)", done)
        }
        front(c.window) { _ in
            self.menus = []
            self.click(at: plus.convert(NSPoint(x: plus.bounds.midX, y: plus.bounds.midY), to: nil), in: self.c.window) { _ in }
            // The click starts the menu's tracking on main; the keys come from a background thread.
            self.after(0.6) {
                self.pickInMenu(AgentsConnect.plusTitle, start: []) { picked, trace in
                    if !picked { self.note("FAIL-ENV parityconnect \(self.engine): \"+\" menu not driven (\(trace))") }
                    self.verifyOpened("[\(picked ? "real click and keys" : "not opened")] + › \(AgentsConnect.plusTitle)", done)
                }
            }
        }
    }

    func verifyOpened(_ what: String, _ done: @escaping () -> Void) {
        runner.waitUntil({ self.onAgents && AgentsSettingsModel.shared.setUpFirst }, timeout: 4) {
            self.check(self.onAgents && AgentsSettingsModel.shared.setUpFirst, "\(what) opens Settings › Agents with Set up first")
            self.closeSettings(done)
        }
    }

    /// Once an app has connected: Access names it, "+" has no Connect Claude…, the Command Bar and Help still do.
    func afterConnecting(_ done: @escaping () -> Void) {
        let spike = AgentSpike(runner: runner)
        let k = SpikeMCPClient(helper: spike.helperPath, args: ["--data-dir", AppPaths.dataDirectory.path, "--client", "Claude"])
        guard k.start() else { check(false, "a client starts"); return done() }
        k.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Claude", "version": "1"]], timeout: 15) { m in
            self.after(0.5) {
                let now = AgentCenter.shared.accessStatus
                self.check(m["result"] != nil && now == "On · Claude connected now", "Access while it's connected: \(now)")
                self.check(!AgentsConnect.neverConnected && !self.c.plusMenu().items.map(\.title).contains(AgentsConnect.plusTitle),
                           "once an app has connected, the \"+\" menu has no Connect Claude… (the Agents folder takes over)")
                self.check(self.c.commandActions().map(\.title).contains(AgentsConnect.commandTitle)
                           && NSApp.helpMenu?.items.contains { $0.title == AgentsConnect.helpTitle } == true,
                           "the Command Bar and Help still offer it")
                k.stop()
                self.runner.waitUntil({ AgentCenter.shared.connectedCount == 0 }, timeout: 4) {
                    let later = AgentCenter.shared.accessStatus
                    self.check(later == "On · Claude allowed", "Access after it disconnects: \(later)")
                    done()
                }
            }
        }
    }

    func descendants(_ v: NSView?) -> [NSView] {
        guard let v else { return [] }
        return v.subviews + v.subviews.flatMap { descendants($0) }
    }

    func finish() {
        AgentSetup.homeOverride = nil
        if let o = menuObserver { NotificationCenter.default.removeObserver(o) }
        AgentCenter.shared.stopAgents(reason: "check-end", off: true)
        runner.finish()
    }
}
#endif
