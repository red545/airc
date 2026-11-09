// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // agentspike: a dev-build prototype (docs/agent-ready.md); public builds compile none of Agent/
import AppKit
import AircKit

/// Agents in Airc (the agentspike prototype, dev builds only). Off by default. When on:
/// - a socket in the data folder takes MCP clients through `airc-mcp` (and, if asked, HTTP on 127.0.0.1 with a token);
/// - each connection uses one profile, and only one the person granted (Dock menu › Agents), never a private window;
/// - its pages live in agent windows that never take focus and aren't on screen;
/// - every call is logged without content (AgentLog.jsonl), the Dock icon wears ✦ while an agent is connected, and
///   Dock menu › Stop Agents closes every connection and agent window.
///
/// Launch options (dev builds): `--agent-server` turns agents on for this run, `--agent-grant=<profile>` grants a
/// profile for this run, `--agent-http` adds the loopback transport, `--agent-headless` brings up the engine and the
/// server with no browser window, `--agent-quit-after=<s>` quits after that long (test runs: an app never outlives its
/// check).
final class AgentCenter {
    static let shared = AgentCenter()

    struct Settings: Codable {
        var enabled = false
        var grantedProfiles: [String] = []
        var http = false
    }

    weak var app: AppDelegate?
    private(set) var settings = Settings()
    private var runEnabled = false
    private var runGrants: [String] = []      // names or IDs from --agent-grant
    private var runHTTP = false
    private(set) var headless = false
    private var server: AgentServer?
    private(set) var windows: [Int: AgentWindow] = [:]
    private(set) lazy var tools: [AgentTool] = makeTools()
    private var connected = 0
    private var idleTimer: Timer?
    private let logQueue = DispatchQueue(label: "airc.agent.log")
    private(set) var driver: AgentPageDriver?
    /// Checks read what happened (AgentSpikeCheck).
    var onEvent: ((String) -> Void)?

    private var dataDir: URL { AppPaths.dataDirectory }
    private var settingsFile: URL { dataDir.appendingPathComponent("agent.json") }
    var logFile: URL { dataDir.appendingPathComponent("AgentLog.jsonl") }
    var socketPath: String { AgentPaths.socket(dataDir: dataDir) }
    var isOn: Bool { settings.enabled || runEnabled }
    var isServing: Bool { server != nil }
    var httpInfo: URL { AgentPaths.httpInfo(dataDir: dataDir) }

    // MARK: Launch

    /// From the app's launch, once profiles are loaded. True: a headless launch, so no browser window opens.
    func launch(app: AppDelegate) -> Bool {
        self.app = app
        let args = CommandLine.arguments
        runEnabled = args.contains("--agent-server") || args.contains("--agent-headless")
        runHTTP = args.contains("--agent-http")
        headless = args.contains("--agent-headless")
        runGrants = args.compactMap { $0.hasPrefix("--agent-grant=") ? String($0.dropFirst("--agent-grant=".count)) : nil }
        if let quit = args.first(where: { $0.hasPrefix("--agent-quit-after=") }).flatMap({ Double($0.dropFirst("--agent-quit-after=".count)) }) {
            // Wall-clock time: a Mac that sleeps must not stretch a test run's life (monotonic time stops in sleep).
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + quit) {
                NSLog("Airc agents: --agent-quit-after reached, quitting")
                self.stopAgents(reason: "quit-after")
                NSApp.terminate(nil)
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(0) }
            }
        }
        loadSettings()
        if isOn { start() }
        guard headless else { return false }
        // A scripted headless run (--automated) makes the profiles it grants by name when they don't exist yet.
        if app.options.isAutomated {
            for name in runGrants where !profiles.contains(where: { $0.id == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                _ = try? app.profiles.createProfile(name: name, emoji: "🤖", color: nil)
            }
        }
        // No browser window: the engine's profiles stay loaded (a hidden keeper window holds them on Chromium), the
        // server runs, and the Dock icon (badge, menu) is the visible sign. Clicking it opens the browser as usual.
        app.keepProfilesLoaded()
        app.windowSession.browserReady = true
        return true
    }

    private func loadSettings() {
        if let data = try? Data(contentsOf: settingsFile), let s = try? JSONDecoder().decode(Settings.self, from: data) { settings = s }
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsFile, options: .atomic)
    }

    // MARK: On, off, stop

    func start() {
        guard server == nil, let app else { return }
        #if canImport(AircCore)
        driver = app.engine is ChromiumEngine ? ChromiumAgentDriver() : WebKitAgentDriver()
        #else
        driver = WebKitAgentDriver()
        #endif
        let s = AgentServer(socketPath: socketPath, handler: { [weak self] line, session, reply in
            self?.handle(line, session, reply) ?? reply(nil)
        }, hello: { [weak self] session in
            guard let self else { return "Airc is quitting" }
            return self.hello(session)   // nil lets the connection in
        })
        if let error = s.start() {
            NSLog("Airc agents: not serving: %@", error)
            onEvent?("server-failed \(error)")
            return
        }
        s.onConnectionsChanged = { [weak self] n in self?.connected = n; self?.updateIndicator() }
        s.onDisconnect = { [weak self] session in self?.sessionEnded(session) }
        if settings.http || runHTTP, let error = s.startHTTP(info: httpInfo) { NSLog("Airc agents: no HTTP: %@", error) }
        server = s
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.closeIdleWindows() }
        log(["event": "server-on", "http": settings.http || runHTTP])
        onEvent?("server-on")
        updateIndicator()
    }

    /// The kill switch: every connection closes and every agent window with it. The server listens again (Stop
    /// isn't Off), unless `off`.
    func stopAgents(reason: String, off: Bool = false) {
        server?.stop()
        server = nil
        idleTimer?.invalidate(); idleTimer = nil
        for w in windows.values { w.close() }
        windows.removeAll()
        connected = 0
        log(["event": "stop", "reason": reason])
        onEvent?("stopped \(reason)")
        if !off, isOn, reason != "quit-after" { start() }
        updateIndicator()
    }

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        if !on { runEnabled = false }
        saveSettings()
        if on { start() } else { stopAgents(reason: "off", off: true) }
    }

    func setGranted(_ profileID: String, _ granted: Bool) {
        settings.grantedProfiles.removeAll { $0 == profileID }
        if granted { settings.grantedProfiles.append(profileID) }
        saveSettings()
        // Taking a grant back ends what uses it.
        if !granted { for w in windows.values where w.profileID == profileID { closeWindow(w) } }
    }

    /// Checks turn agents on in their own data folder (never the owner's).
    func enableForCheck(grants: [String], http: Bool) {
        runEnabled = true
        runGrants = grants
        runHTTP = http
        start()
    }

    // MARK: Profiles and grants

    var profiles: [Profile] { app?.store.orderedProfiles ?? [] }

    func isGranted(_ p: Profile) -> Bool {
        settings.grantedProfiles.contains(p.id) || runGrants.contains(p.id)
            || runGrants.contains { $0.caseInsensitiveCompare(p.name) == .orderedSame }
    }

    func resolveProfile(_ ask: String) -> Result<Profile, AgentReason> {
        let byID = profiles.filter { $0.id == ask }
        let byName = profiles.filter { $0.name.caseInsensitiveCompare(ask.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        guard let p = byID.first ?? (byName.count == 1 ? byName.first : nil) else {
            return .failure(AgentReason(byName.count > 1 ? "Several profiles are named \(ask): use its id from list_profiles." : "No profile \(ask) is open to agents."))
        }
        guard isGranted(p) else { return .failure(AgentReason("The profile \(p.name) isn't open to agents. In Airc: Dock menu › Agents › Allow in \(p.name).")) }
        return .success(p)
    }

    /// The hello's answer: nil lets the connection in.
    func hello(_ session: AgentSession) -> String? {
        guard isOn else { return "Agents are off in Airc." }
        if let ask = session.requestedProfile {
            switch resolveProfile(ask) {
            case .success(let p): session.profileID = p.id
            case .failure(let why): return why.text
            }
        }
        log(["event": "connect", "session": session.id, "client": session.client, "via": session.via])
        onEvent?("connect \(session.client)")
        return nil
    }

    private func sessionEnded(_ session: AgentSession) {
        // A socket client's windows go with it (Claude Code starts its MCP servers per session).
        for w in windows.values where w.ownerKey == session.ownerKey { closeWindow(w) }
        log(["event": "disconnect", "session": session.id, "client": session.client])
        onEvent?("disconnect \(session.client)")
        updateIndicator()
    }

    // MARK: Requests

    private func handle(_ line: Data, _ session: AgentSession, _ reply: @escaping (Data?) -> Void) {
        // HTTP: each request names its profile (X-Airc-Profile).
        if !session.persistent, session.profileID == nil, let ask = session.requestedProfile, case .success(let p) = resolveProfile(ask) {
            session.profileID = p.id
        }
        if !session.persistent, !isOn { return reply(AgentMCP.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32000, "message": "Agents are off in Airc."]])) }
        AgentMCP.handle(line, session: session, tools: tools, log: { [weak self] tool, result, ms in
            self?.logCall(tool, session, result, ms)
        }, reply: reply)
    }

    func session(_ s: AgentSession) -> Result<Profile, AgentReason> {
        guard let id = s.profileID, let p = profiles.first(where: { $0.id == id }) else {
            return .failure(AgentReason("Choose a profile first: list_profiles, then use_profile."))
        }
        guard isGranted(p) else { return .failure(AgentReason("The profile \(p.name) is no longer open to agents.")) }
        return .success(p)
    }

    func listProfiles(_ s: AgentSession) -> AgentResult {
        let open = profiles.filter(isGranted)
        let list: [[String: Any]] = open.map { ["id": $0.id, "name": $0.name, "emoji": $0.emoji, "inUse": $0.id == s.profileID] }
        return .json(["profiles": list, "otherProfiles": profiles.count - open.count,
                      "note": "Private windows are never open to agents."])
    }

    func useProfile(_ ask: String, _ s: AgentSession) -> AgentResult {
        switch resolveProfile(ask) {
        case .failure(let why): return .error(why.text)
        case .success(let p):
            if let current = s.profileID, current != p.id {
                return .error("This connection uses another profile. Reconnect to use \(p.name).")
            }
            s.profileID = p.id
            return .json(["profile": ["id": p.id, "name": p.name]])
        }
    }

    func mine(_ s: AgentSession) -> [AgentWindow] {
        windows.values.filter { $0.ownerKey == s.ownerKey && $0.profileID == s.profileID }.sorted { $0.id < $1.id }
    }

    func describe(_ w: AgentWindow) -> [String: Any] {
        let tab = w.activeTab
        return ["window": w.id, "width": Int(w.size.width), "height": Int(w.size.height), "tabs": w.tabs.count,
                "tab": w.activeTabID.map { $0 as Any } ?? NSNull(), "title": tab?.title ?? "", "url": tab?.url?.absoluteString ?? "",
                "loading": tab?.isLoading ?? false, "onScreen": false, "key": w.window.isKeyWindow]
    }

    func tabList(_ w: AgentWindow) -> [[String: Any]] {
        w.tabs.map { ["tab": $0.id, "title": $0.tab.title, "url": $0.tab.url?.absoluteString ?? "", "loading": $0.tab.isLoading,
                      "shown": $0.id == w.activeTabID] }
    }

    func listWindows(_ s: AgentSession) -> AgentResult {
        if case .failure(let why) = session(s) { return .error(why.text) }
        return .json(["windows": mine(s).map(describe)])
    }

    func openWindow(_ a: [String: Any], _ s: AgentSession, _ done: @escaping (AgentResult) -> Void) {
        let profile: Profile
        switch session(s) { case .failure(let why): return done(.error(why.text)); case .success(let p): profile = p }
        guard let app, let driver else { return done(.error("Airc isn't ready.")) }
        guard mine(s).count < 8 else { return done(.error("This connection has 8 agent windows open: close one first.")) }
        let url: URL?
        if let raw = a["url"] {
            guard let u = allowedURL(raw) else { return done(.error("Only http(s) addresses (or about:blank).")) }
            url = u
        } else { url = nil }
        let width = CGFloat(max(320, min(2560, a["width"] as? Int ?? 1280)))
        let height = CGFloat(max(240, min(1600, a["height"] as? Int ?? 800)))
        let visible = (a["keepVisible"] as? Bool) ?? true    // checks compare the engine's hidden-window behaviour
        app.profiles.whenLoaded(profile.id, { [weak self] engineProfile in
            guard let self else { return }
            let w = AgentWindow(engine: app.engine, profile: engineProfile, profileID: profile.id, ownerKey: s.ownerKey,
                                client: s.client, size: CGSize(width: width, height: height), driver: driver, keepsVisible: visible)
            self.windows[w.id] = w
            s.currentWindow = w.id
            self.updateIndicator()
            self.onEvent?("window-open \(w.id)")
            w.openTab(url) { _ in
                guard url != nil, let tab = w.activeTab else { return done(.json(self.describe(w))) }
                self.waitForLoad(w, tab, timeout: 15) { _ in done(.json(self.describe(w))) }
            }
        }, failed: { done(.error("The profile couldn't load.")) })
    }

    func closeWindow(_ w: AgentWindow) {
        windows[w.id] = nil
        w.close()
        onEvent?("window-close \(w.id)")
        updateIndicator()
    }

    private func closeIdleWindows() {
        // HTTP clients' windows have no connection to end with them: 15 idle minutes do.
        for w in windows.values where w.ownerKey.hasPrefix("http-") && Date().timeIntervalSince(w.lastUsed) > 900 { closeWindow(w) }
    }

    func withWindow(_ a: [String: Any], _ s: AgentSession, _ done: @escaping (AgentResult) -> Void, _ body: (AgentWindow) -> Void) {
        if case .failure(let why) = session(s) { return done(.error(why.text)) }
        let current = s.currentWindow.flatMap { windows[$0] == nil ? nil : $0 }
        let id = (a["window"] as? Int) ?? current ?? mine(s).last?.id
        guard let id, let w = windows[id], w.ownerKey == s.ownerKey, w.profileID == s.profileID else {
            return done(.error(a["window"] == nil ? "No agent window yet: open_window first." : "No such agent window in this connection's profile."))
        }
        s.currentWindow = w.id
        w.lastUsed = Date()
        body(w)
    }

    func withTab(_ a: [String: Any], _ s: AgentSession, _ done: @escaping (AgentResult) -> Void, _ body: (AgentWindow, EngineTab) -> Void) {
        withWindow(a, s, done) { w in
            guard let tab = w.activeTab, !tab.isClosed else { return done(.error("The window has no tab: open_tab first.")) }
            body(w, tab)
        }
    }

    // MARK: The log (metadata only, never content)

    private func log(_ entry: [String: Any]) {
        var e = entry
        e["t"] = ISO8601DateFormatter().string(from: Date())
        let file = logFile
        logQueue.async {
            guard var data = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            _ = AgentPaths.writePrivate(data, to: file.path, append: true)
        }
    }

    private func logCall(_ tool: String, _ s: AgentSession, _ result: AgentResult, _ ms: Double) {
        var e: [String: Any] = ["event": "call", "tool": tool, "session": s.id, "client": s.client, "via": s.via,
                                "ok": !result.isError, "ms": Int(ms.rounded())]
        if let p = s.profileID { e["profile"] = p }
        if let id = s.currentWindow, let w = windows[id] {
            e["window"] = id
            e["host"] = w.activeTab?.url?.host ?? ""
        }
        // Sizes only: how much went back, never what.
        e["bytes"] = result.content.reduce(0) { $0 + (($1["text"] as? String)?.utf8.count ?? 0) + (($1["data"] as? String)?.count ?? 0) }
        log(e)
    }

    // MARK: What the person sees

    /// ✦ on the Dock icon while an agent is connected or has a window open.
    private func updateIndicator() {
        let busy = connected > 0 || !windows.isEmpty
        NSApp.dockTile.badgeLabel = busy ? "✦" : nil
    }

    var badgeShown: Bool { NSApp.dockTile.badgeLabel == "✦" }

    /// Dock menu › Agents (dev builds): on/off, per-profile grants, Stop Agents.
    func addDockItems(to menu: NSMenu) {
        let item = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Agents")
        let status = connected > 0 ? "\(connected) connected · \(windows.count) window\(windows.count == 1 ? "" : "s")" : (isOn ? "On, none connected" : "Off")
        let head = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        head.isEnabled = false
        sub.addItem(head)
        sub.addItem(AgentMenuItem(isOn ? "Turn Agents Off" : "Let Agents Use Airc") { [weak self] in
            guard let self else { return }
            self.setEnabled(!self.isOn)
        })
        sub.addItem(.separator())
        for p in profiles {
            let granted = isGranted(p)
            let i = AgentMenuItem("Allow in \(p.name)") { [weak self] in self?.setGranted(p.id, !granted) }
            i.state = granted ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        let stop = AgentMenuItem("Stop Agents") { [weak self] in self?.stopAgents(reason: "person") }
        stop.isEnabled = connected > 0 || !windows.isEmpty
        sub.addItem(stop)
        item.submenu = sub
        // First, so the menu's own items keep their places (Little Arc's stay last).
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }
}

/// Why a profile can't be used, in words for the agent.
struct AgentReason: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

/// A Dock menu item that runs a closure.
final class AgentMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
#endif
