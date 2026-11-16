// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// Agents in Airc (docs/user/agents.md): AI apps such as Claude use Airc through its MCP connector. On by default
/// (Settings › Agents › "Let AI apps use Airc"). When on:
/// - a 0600 socket in the data folder takes MCP clients through the bundled `airc-mcp` helper (Contents/Helpers);
/// - the first connection from an app Airc hasn't seen asks once: "Allow ‘Claude’ to use Airc?" (AgentApproval.swift),
///   and the answer is kept per app, identified by its code signature (AgentClientIdentity.swift);
/// - each connection uses one profile, any normal profile the person hasn't switched off, with its logins and cookies;
///   private windows are never reachable (agent tools only see agent windows);
/// - its pages live in agent windows that never take focus and aren't on screen;
/// - no tool returns saved passwords, passkeys, cookies or Keychain items: saved logins only fill (fill_saved_login);
/// - every call is logged without content (AgentLog.jsonl), the Dock icon wears ✦ while an agent is connected, and
///   Dock menu › Stop Agents closes every connection and agent window.
///
/// Launch options: `--agent-headless` brings up the engine and the server with no browser window. Test builds also take
/// `--agent-server` (on for this run), `--agent-grant=<profile>` (only these profiles for this run), `--agent-http` (the
/// loopback transport), `--agent-approve=allow|deny` (answer approvals without asking) and `--agent-quit-after=<s>`.
final class AgentCenter {
    static let shared = AgentCenter()
    /// Posted on the main thread whenever what Settings › Agents shows changes.
    static let changed = Notification.Name("AircAgentsChanged")

    struct Settings: Codable {
        var enabled = true
        /// Profiles the person switched off (all normal profiles are open to agents by default).
        var blockedProfiles: [String] = []
        /// Apps the person answered, by identity key.
        var clients: [AgentClient] = []
        /// Settings › Agents › "Show agent pages in front": each agent page shows live in the profile's window as it
        /// opens (Watch, in the Agents folder) instead of only off screen. Off by default.
        var showInFront = false
        /// Settings › Agents › Other devices: "Allow other devices on your Tailscale network" (AgentRemote.swift). Off
        /// by default; it needs agents on too.
        var remoteEnabled = false
        /// The port it listens on (the same every launch, so a paired device's URL keeps working).
        var remotePort: Int?

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            blockedProfiles = try c.decodeIfPresent([String].self, forKey: .blockedProfiles) ?? []
            clients = try c.decodeIfPresent([AgentClient].self, forKey: .clients) ?? []
            showInFront = try c.decodeIfPresent(Bool.self, forKey: .showInFront) ?? false
            remoteEnabled = try c.decodeIfPresent(Bool.self, forKey: .remoteEnabled) ?? false
            remotePort = try c.decodeIfPresent(Int.self, forKey: .remotePort)
        }
    }

    weak var app: AppDelegate?
    private(set) var settings = Settings()
    private var runEnabled = false
    private var runGrants: [String] = []      // test builds: names or IDs from --agent-grant
    private var runHTTP = false
    private(set) var headless = false
    private var server: AgentServer?
    /// Other devices on the Tailscale network (AgentRemote.swift), while that's on.
    private(set) var remote: RemoteAgentListener?
    /// The paired devices: Airc's Keychain item (memory only in scripted runs, never the account's Keychain).
    private(set) lazy var remoteStore = RemoteDeviceStore(keychain: !(app?.options.isAutomated ?? true))
    private var runRemote = false            // test builds: --agent-remote (on for this run)
    #if AIRC_TESTING
    /// Test builds: `--agent-remote-port=<n>`, or a check's own port.
    var runRemotePort: UInt16?
    /// Test builds: `--agent-remote-pair-file=<path>` (the end-to-end run, headless): once listening, a pairing code
    /// and the command Settings would show are written there (0600).
    private var runRemotePairFile: String?
    #endif
    private(set) var windows: [Int: AgentWindow] = [:]
    private(set) lazy var tools: [AgentTool] = makeTools()
    /// Connections that passed the hello, by session id (main thread).
    private(set) var live: [Int: AgentSession] = [:]
    private var idleTimer: Timer?
    private let logQueue = DispatchQueue(label: "airc.agent.log")
    private(set) var driver: AgentPageDriver?
    let approvals = AgentApprovals()
    private var launched = false
    /// Checks read what happened (AgentSpikeCheck).
    var onEvent: ((String) -> Void)?
    /// Windows whose page the person took over (Take over), by window id: the connection is told once.
    struct TakenOver { let owner: String; let message: String; var told = false }
    var takenOver: [Int: TakenOver] = [:]

    private var dataDir: URL { AppPaths.dataDirectory }
    private var settingsFile: URL { dataDir.appendingPathComponent("Agents.json") }
    var logFile: URL { dataDir.appendingPathComponent("AgentLog.jsonl") }
    var socketPath: String { AgentPaths.socket(dataDir: dataDir) }
    var isOn: Bool { settings.enabled || runEnabled }
    var isServing: Bool { server != nil }
    var httpInfo: URL { AgentPaths.httpInfo(dataDir: dataDir) }
    var connectedCount: Int { live.count }

    // MARK: Launch

    /// From the app's launch, once profiles are loaded. True: a headless launch, so no browser window opens.
    func launch(app: AppDelegate) -> Bool {
        self.app = app
        launched = true
        let args = CommandLine.arguments
        headless = args.contains("--agent-headless")
        #if AIRC_TESTING
        runEnabled = args.contains("--agent-server") || headless
        runHTTP = args.contains("--agent-http")
        runRemote = args.contains("--agent-remote")
        runRemotePairFile = args.first { $0.hasPrefix("--agent-remote-pair-file=") }.map { String($0.dropFirst("--agent-remote-pair-file=".count)) }
        runRemotePort = args.first { $0.hasPrefix("--agent-remote-port=") }.flatMap { UInt16($0.dropFirst("--agent-remote-port=".count)) }
        runGrants = args.compactMap { $0.hasPrefix("--agent-grant=") ? String($0.dropFirst("--agent-grant=".count)) : nil }
        if let a = args.first(where: { $0.hasPrefix("--agent-approve=") }) { approvals.automatic = a.hasSuffix("=allow") }
        if let quit = args.first(where: { $0.hasPrefix("--agent-quit-after=") }).flatMap({ Double($0.dropFirst("--agent-quit-after=".count)) }) {
            // Wall-clock time: a Mac that sleeps must not stretch a test run's life (monotonic time stops in sleep).
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + quit) {
                NSLog("Airc agents: --agent-quit-after reached, quitting")
                self.stopAgents(reason: "quit-after")
                NSApp.terminate(nil)
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { exit(0) }
            }
        }
        #endif
        loadSettings()
        observeAutofill()
        AgentModelSettings.shared.launch(automated: app.options.isAutomated)
        // Scripted runs serve only when a check asks (enableForCheck) or the run says so: a test launch must never
        // put a socket in a folder another run is using, nor ask approvals nobody answers.
        if isOn, !app.options.isAutomated || runEnabled { start() }
        guard headless else { return false }
        #if AIRC_TESTING
        // A scripted headless run (--automated) makes the profiles it grants by name when they don't exist yet.
        if app.options.isAutomated {
            for name in runGrants where !profiles.contains(where: { $0.id == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                _ = try? app.profiles.createProfile(name: name, emoji: "🤖", color: nil)
            }
        }
        #endif
        // No browser window: the engine's profiles stay loaded (a hidden keeper window holds them on Chromium), the
        // server runs, and the Dock icon (badge, menu) is the visible sign. Clicking it opens the browser as usual.
        app.keepProfilesLoaded()
        app.windowSession.browserReady = true
        return true
    }

    private func loadSettings() {
        if let data = try? Data(contentsOf: settingsFile), let s = try? JSONDecoder.agents.decode(Settings.self, from: data) { settings = s }
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder.agents.encode(settings) else { return }
        _ = AgentPaths.writePrivate(data, to: settingsFile.path)
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: AgentCenter.changed, object: self)
    }

    // MARK: On, off, stop

    /// The page driver for agent windows (the server's and the Airc Agent panel's).
    func ensureDriver() {
        guard driver == nil, let app else { return }
        #if canImport(AircCore)
        driver = app.engine is ChromiumEngine ? ChromiumAgentDriver() : WebKitAgentDriver()
        #else
        driver = WebKitAgentDriver()
        #endif
    }

    func start() {
        guard server == nil, app != nil else { return }
        ensureDriver()
        let s = AgentServer(socketPath: socketPath, handler: { [weak self] line, session, reply in
            self?.handle(line, session, reply) ?? reply(nil)
        }, hello: { [weak self] session, answer in
            guard let self else { return answer("Airc is quitting") }
            self.hello(session, answer)   // nil lets the connection in
        })
        if let error = s.start() {
            NSLog("Airc agents: not serving: %@", error)
            onEvent?("server-failed \(error)")
            return
        }
        s.onDisconnect = { [weak self] session in self?.sessionEnded(session) }
        #if AIRC_TESTING
        if runHTTP, let error = s.startHTTP(info: httpInfo) { NSLog("Airc agents: no HTTP: %@", error) }
        #endif
        server = s
        if remoteWanted { startRemote() }
        if runHTTP {
            // HTTP clients' windows have no connection to end with them: 15 idle minutes do.
            idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.closeIdleWindows() }
            idleTimer?.tolerance = 30
        }
        AgentSetup.refreshStableHelper()
        log(["event": "server-on", "http": runHTTP])
        onEvent?("server-on")
        updateIndicator()
    }

    /// The kill switch: every connection closes and every agent window with it. The server listens again (Stop
    /// isn't Off), unless `off`.
    func stopAgents(reason: String, off: Bool = false) {
        AgentRunCenter.shared.stopFromFolder()
        stopRemote()
        server?.stop()
        server = nil
        idleTimer?.invalidate(); idleTimer = nil
        for w in windows.values { AgentActivity.shared.windowClosed(w, .stopped) }
        for w in windows.values { w.close() }
        windows.removeAll()
        live.removeAll()
        approvals.cancelAll()
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

    // MARK: Other devices (AgentRemote.swift)

    var remoteWanted: Bool { isOn && (settings.remoteEnabled || runRemote) }
    var remotePort: UInt16 {
        #if AIRC_TESTING
        if let p = runRemotePort { return p }
        #endif
        return settings.remotePort.flatMap { UInt16(exactly: $0) } ?? RemoteAgentListener.defaultPort
    }

    /// Settings › Agents › Other devices › "Allow other devices on your Tailscale network".
    func setRemoteEnabled(_ on: Bool) {
        settings.remoteEnabled = on
        if !on { runRemote = false }
        saveSettings()
        if remoteWanted, server != nil { startRemote() } else { stopRemote() }
    }

    private func startRemote() {
        guard remote == nil else { return }
        let r = RemoteAgentListener(port: remotePort, store: remoteStore, handler: { [weak self] line, session, reply in
            self?.handle(line, session, reply) ?? reply(nil)
        }, hello: { [weak self] session, answer in
            guard let self else { return answer("Airc is quitting") }
            self.hello(session, answer)
        })
        r.onChange = { [weak self] in
            #if AIRC_TESTING
            self?.writePairFile()
            #endif
            self?.changed()
        }
        r.onEnded = { [weak self] session in self?.sessionEnded(session) }
        r.onLog = { [weak self] entry in DispatchQueue.main.async { self?.log(entry) } }
        remote = r
        r.start()
        log(["event": "remote-on", "port": Int(remotePort)])
        changed()
    }

    private func stopRemote() {
        guard let r = remote else { return }
        remote = nil
        r.stop()
        log(["event": "remote-off"])
        changed()
    }

    /// The paired devices, newest first.
    var remoteDevices: [RemoteDevice] {
        (remote?.devices ?? remoteStore.load().devices).sorted { $0.paired > $1.paired }
    }

    /// Revoke in Settings: the device's token stops working at once, its sessions and windows end, and its apps'
    /// answers are forgotten (pairing again asks again).
    func revokeDevice(_ id: String) {
        let name = remoteDevices.first { $0.id == id }?.name ?? "?"
        if let remote { remote.revoke(id) } else {
            var r = remoteStore.load()
            r.revoke(id)
            remoteStore.save(r)
        }
        let keys = settings.clients.map(\.key).filter { $0.hasPrefix("remote:\(id)|") }
        for k in keys { removeClient(k) }
        log(["event": "remote-revoked", "device": name])
        onEvent?("remote-revoked \(id)")
        changed()
    }

    /// Settings › Agents › "Show agent pages in front".
    func setShowInFront(_ on: Bool) {
        settings.showInFront = on
        saveSettings()
    }

    func setGranted(_ profileID: String, _ granted: Bool) {
        settings.blockedProfiles.removeAll { $0 == profileID }
        if !granted { settings.blockedProfiles.append(profileID) }
        #if AIRC_TESTING
        if granted, !runGrants.isEmpty, !runGrants.contains(profileID) { runGrants.append(profileID) }
        if !granted { runGrants.removeAll { $0 == profileID || profiles.first(where: { $0.id == profileID })?.name.caseInsensitiveCompare($0) == .orderedSame } }
        #endif
        saveSettings()
        // Taking a profile back ends what uses it.
        if !granted { for w in windows.values where w.profileID == profileID { closeWindow(w) } }
    }

    #if AIRC_TESTING
    private func writePairFile() {
        guard let path = runRemotePairFile, let r = remote, let base = remoteBaseURL else { return }
        let code = r.pairingCode ?? r.startPairing()
        let info: [String: Any] = ["code": code, "base": base, "command": AgentCenter.remoteCommand(base: base, code: code)]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) { _ = AgentPaths.writePrivate(data, to: path) }
    }

    /// Marketing shots: Settings › Agents › Other devices as if on and listening (made-up addresses, name and devices;
    /// nothing binds, nothing is saved). `nil` puts it back.
    func stageRemoteForMarketing(_ stage: (addresses: [String], host: String, devices: [(name: String, paired: Date, used: Date?, address: String)])?) {
        if let stage {
            guard remote == nil else { return }
            let r = RemoteAgentListener(port: RemoteAgentListener.defaultPort, store: RemoteDeviceStore(keychain: false),
                                        handler: { _, _, reply in reply(nil) }, hello: { _, answer in answer("marketing") })
            r.onChange = { [weak self] in self?.changed() }
            settings.remoteEnabled = true
            remote = r
            r.stageForMarketing(addresses: stage.addresses, host: stage.host, devices: stage.devices)
        } else {
            remote?.cancelPairing()
            remote = nil
            settings.remoteEnabled = false
        }
        changed()
    }

    /// Checks: the tailnet listener on for this run (`--agent-remote` does the same at launch).
    func enableRemoteForCheck() {
        runRemote = true
        if remoteWanted, server != nil { startRemote() }
    }

    /// Checks turn agents on in their own data folder (never the owner's). `grants`: only these profiles for the run.
    func enableForCheck(grants: [String], http: Bool) {
        runEnabled = true
        runGrants = grants
        runHTTP = http
        start()
    }
    #endif

    // MARK: Apps (clients)

    func client(_ key: String) -> AgentClient? { settings.clients.first { $0.key == key } }

    /// Remove in Settings › Agents: forgets the answer, ends the app's connections and closes its windows. Its next
    /// connection asks again.
    func removeClient(_ key: String) {
        settings.clients.removeAll { $0.key == key }
        saveSettings()
        disconnect(clientKey: key, reason: "removed")
    }

    private func disconnect(clientKey key: String, reason: String) {
        let ended = live.values.filter { $0.clientKey == key }
        for s in ended {
            live[s.id] = nil
            for w in windows.values where w.ownerKey == s.ownerKey { closeWindow(w, end: .stopped) }
            AgentActivity.shared.sessionEnded(s.ownerKey, .stopped)
        }
        server?.disconnect { $0.clientKey == key }
        remote?.disconnect { $0.clientKey == key }
        if !ended.isEmpty { log(["event": "client-" + reason, "client": ended[0].client]) }
        onEvent?("client-\(reason) \(key)")
        updateIndicator()
    }

    private func remember(_ identity: AgentClientIdentity, allowed: Bool) {
        settings.clients.removeAll { $0.key == identity.key }
        settings.clients.append(AgentClient(key: identity.key, name: identity.displayName, detail: identity.detail,
                                            allowed: allowed, decided: Date(), lastUsed: allowed ? Date() : nil))
        saveSettings()
    }

    // MARK: Stop one app, Take over (the Agents folder, Watch)

    static func stoppedMessage(_ name: String) -> String {
        "The person stopped \(name) in Airc, so Airc refuses its calls. They can let it work again from the Agents folder in Airc's sidebar, or Settings › Agents."
    }

    /// A tools/call refusal for this connection, before the tool runs.
    func refusal(for s: AgentSession) -> String? {
        guard let key = s.clientKey, let c = client(key), c.stopped == true else { return nil }
        return AgentCenter.stoppedMessage(c.name)
    }

    func isStopped(_ clientKey: String) -> Bool { client(clientKey)?.stopped == true }

    /// Stop in the Agents folder or Watch: the app's agent windows close, its connections stay open but every call
    /// fails with a clear message, and new connections are refused, until the person allows it again.
    func stopClient(_ key: String) {
        // The Airc Agent panel (Agent/AgentBridge.swift): Stop ends its run; there's no app to refuse later.
        if key == AgentBridge.clientKey { return AgentRunCenter.shared.stopFromFolder() }
        if let i = settings.clients.firstIndex(where: { $0.key == key }) {
            settings.clients[i].stopped = true
            saveSettings()
        }
        let sessions = live.values.filter { $0.clientKey == key }
        for s in sessions {
            for w in windows.values where w.ownerKey == s.ownerKey { closeWindow(w, end: .stopped) }
            AgentActivity.shared.sessionEnded(s.ownerKey, .stopped)
        }
        log(["event": "client-stopped", "client": sessions.first?.client ?? key])
        onEvent?("client-stopped \(key)")
        updateIndicator()
    }

    func allowAgain(_ key: String) {
        guard let i = settings.clients.firstIndex(where: { $0.key == key }), settings.clients[i].stopped == true else { return }
        settings.clients[i].stopped = nil
        saveSettings()
        onEvent?("client-allowed-again \(key)")
    }

    /// Take over: the agent tab's page (same profile, same page, its state) becomes a normal tab in `c`'s sidebar, in
    /// the current Space when it has the agent's profile, else that profile's first Space. The connection is told the
    /// next time it uses the window. Nil when done, else why not.
    func takeOver(window id: Int, tab tabID: Int, into c: WindowController) -> String? {
        guard let w = windows[id], let page = w.tab(tabID), !page.isClosed else { return "The agent's page is gone." }
        let store = c.store
        let spaceID: String
        if store.space(c.currentSpaceID)?.profileID == w.profileID { spaceID = c.currentSpaceID }
        else if let other = store.spaces(usingProfile: w.profileID).first { spaceID = other.id }
        else { return "No Space in this window uses the agent's profile." }
        let rowID = AgentActivityModel.rowID(window: id, tab: tabID)
        // First, so the row reads "You took over" and not "Done" when the tab leaves the window.
        AgentActivity.shared.ended(rowID, .takenOver)
        guard let detached = w.detach(tabID) else { return "The agent's page is gone." }
        guard c.adoptMovedPage(detached, inSpace: spaceID) else {
            // The engine couldn't move it: the agent keeps it.
            w.reattach(detached)
            return "Airc couldn't move this page into the window."
        }
        let name = w.clientName ?? w.client
        let message = "The person took over this page in Airc: it's their tab now, and agent window \(id) no longer has it. "
            + (w.tabs.isEmpty ? "Open a new window (open_window) to keep working." : "The window's other tabs are still yours (list_tabs).")
        takenOver[id] = TakenOver(owner: w.ownerKey, message: message)
        if w.tabs.isEmpty { closeWindow(w) }
        log(["event": "taken-over", "client": w.client, "window": id])
        onEvent?("taken-over \(id) \(name)")
        updateIndicator()
        return nil
    }

    // MARK: Profiles

    var profiles: [Profile] { app?.store.orderedProfiles ?? [] }

    func isGranted(_ p: Profile) -> Bool {
        #if AIRC_TESTING
        if !runGrants.isEmpty {
            return runGrants.contains(p.id) || runGrants.contains { $0.caseInsensitiveCompare(p.name) == .orderedSame }
        }
        #endif
        return !settings.blockedProfiles.contains(p.id)
    }

    var grantedProfiles: [Profile] { profiles.filter(isGranted) }

    func resolveProfile(_ ask: String) -> Result<Profile, AgentReason> {
        let byID = profiles.filter { $0.id == ask }
        let byName = profiles.filter { $0.name.caseInsensitiveCompare(ask.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        guard let p = byID.first ?? (byName.count == 1 ? byName.first : nil) else {
            return .failure(AgentReason(byName.count > 1 ? "Several profiles are named \(ask): use its id from list_profiles." : "No profile \(ask) is open to agents."))
        }
        guard isGranted(p) else { return .failure(AgentReason("The profile \(p.name) isn't open to agents. In Airc: Settings › Agents › Profiles.")) }
        return .success(p)
    }

    /// The Airc Agent panel's session (in process, no socket): live while its run has a window.
    func admitPanel(_ s: AgentSession) {
        live[s.id] = s
        log(["event": "connect", "session": s.id, "client": s.client, "app": s.clientName ?? s.client, "via": s.via])
        updateIndicator()
    }

    func endPanel(_ s: AgentSession, _ end: AgentTabRow.End) {
        for w in windows.values where w.ownerKey == s.ownerKey { closeWindow(w, end: end) }
        AgentActivity.shared.sessionEnded(s.ownerKey, end)
        if live.removeValue(forKey: s.id) != nil { log(["event": "disconnect", "session": s.id, "client": s.client]) }
        updateIndicator()
    }

    // MARK: The hello

    /// The hello's answer: nil lets the connection in. An app Airc hasn't seen waits for the person's answer.
    func hello(_ session: AgentSession, _ answer: @escaping (String?) -> Void) {
        guard isOn else { return answer("Agents are off in Airc (Settings › Agents).") }
        if let ask = session.requestedProfile {
            switch resolveProfile(ask) {
            case .success(let p): session.profileID = p.id
            case .failure(let why): return answer(why.text)
            }
        }
        let identity = AgentClientIdentity.resolve(session: session)
        session.clientKey = identity.key
        session.clientName = identity.displayName
        let admit = { [weak self] in
            guard let self else { return answer("Airc is quitting") }
            if let i = self.settings.clients.firstIndex(where: { $0.key == identity.key }) {
                self.settings.clients[i].lastUsed = Date()
                self.saveSettings()
            }
            // One profile open to agents: the connection uses it without asking.
            if session.profileID == nil, self.grantedProfiles.count == 1 { session.profileID = self.grantedProfiles[0].id }
            self.live[session.id] = session
            self.log(["event": "connect", "session": session.id, "client": session.client, "app": identity.displayName, "via": session.via])
            self.onEvent?("connect \(session.client)")
            self.updateIndicator()
            answer(nil)
        }
        if let known = client(identity.key) {
            if known.stopped == true {
                onEvent?("refused-stopped \(identity.key)")
                return answer(AgentCenter.stoppedMessage(known.name))
            }
            guard known.allowed else {
                onEvent?("refused \(identity.key)")
                return answer("You chose not to let \(known.name) use Airc. To change that: Airc › Settings › Agents.")
            }
            return admit()
        }
        onEvent?("asking \(identity.key)")
        approvals.ask(identity, profiles: grantedProfiles.map(\.name)) { [weak self] decision in
            guard let self else { return answer("Airc is quitting") }
            switch decision {
            case .allow:
                self.remember(identity, allowed: true)
                self.onEvent?("allowed \(identity.key)")
                admit()
            case .deny:
                self.remember(identity, allowed: false)
                self.onEvent?("denied \(identity.key)")
                answer("You chose not to let \(identity.displayName) use Airc. To change that: Airc › Settings › Agents.")
            case .noAnswer:
                self.onEvent?("unanswered \(identity.key)")
                answer("Airc asked whether \(identity.displayName) may use it, and got no answer. Connect again to be asked again.")
            }
        }
    }

    private func sessionEnded(_ session: AgentSession) {
        // A socket client's windows go with it (Claude Code starts its MCP servers per session).
        for w in windows.values where w.ownerKey == session.ownerKey { closeWindow(w) }
        AgentActivity.shared.sessionEnded(session.ownerKey, .done)
        if live.removeValue(forKey: session.id) != nil {
            log(["event": "disconnect", "session": session.id, "client": session.client])
            onEvent?("disconnect \(session.client)")
        }
        updateIndicator()
    }

    // MARK: Requests

    private func handle(_ line: Data, _ session: AgentSession, _ reply: @escaping (Data?) -> Void) {
        // HTTP (test builds): each request names its profile (X-Airc-Profile).
        if !session.persistent, session.profileID == nil, let ask = session.requestedProfile, case .success(let p) = resolveProfile(ask) {
            session.profileID = p.id
        }
        if !session.persistent, !isOn { return reply(AgentMCP.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32000, "message": "Agents are off in Airc."]])) }
        // A removed app's connection may still have a request in flight.
        if session.persistent, live[session.id] == nil {
            return reply(AgentMCP.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32000, "message": "This connection was ended in Airc."]]))
        }
        var call: AgentActivity.Call?
        AgentMCP.handle(line, session: session, tools: tools, gate: { [weak self] _ in
            self?.refusal(for: session)
        }, began: { [weak self] tool, args in
            guard let self else { return }
            call = AgentActivity.shared.began(tool, args, session: session, center: self)
        }, log: { [weak self] tool, result, ms in
            self?.logCall(tool, session, result, ms)
            if let c = call { AgentActivity.shared.finished(c, isError: result.isError) }
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
        let open = grantedProfiles
        let list: [[String: Any]] = open.map { ["id": $0.id, "name": $0.name, "emoji": $0.emoji, "inUse": $0.id == s.profileID] }
        return .json(["profiles": list, "otherProfiles": profiles.count - open.count,
                      "note": "Each profile has its own signed-in sites. Private windows are never open to agents."])
    }

    func useProfile(_ ask: String, _ s: AgentSession) -> AgentResult {
        switch resolveProfile(ask) {
        case .failure(let why): return .error(why.text)
        case .success(let p):
            if let current = s.profileID, current != p.id, !mine(s).isEmpty {
                return .error("This connection has windows in another profile. Close them, or reconnect, to use \(p.name).")
            }
            s.profileID = p.id
            return .json(["profile": ["id": p.id, "name": p.name]])
        }
    }

    func mine(_ s: AgentSession) -> [AgentWindow] {
        windows.values.filter { $0.ownerKey == s.ownerKey && $0.profileID == s.profileID }.sorted { $0.id < $1.id }
    }

    func isAgentTab(_ tab: EngineTab) -> Bool {
        windows.values.contains { $0.tabs.contains { $0.tab === tab } }
    }

    func agentWindow(of tab: EngineTab) -> AgentWindow? {
        windows.values.first { $0.tabs.contains { $0.tab === tab } }
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
            // The connection may have ended (or been removed) while the profile loaded.
            guard !s.persistent || self.live[s.id] != nil else { return done(.error("This connection was ended in Airc.")) }
            let w = AgentWindow(engine: app.engine, profile: engineProfile, profileID: profile.id, ownerKey: s.ownerKey,
                                client: s.client, size: CGSize(width: width, height: height), driver: driver, keepsVisible: visible)
            w.clientName = s.clientName ?? s.client
            w.clientKey = s.clientKey
            w.onTabsChanged = { [weak self, weak w] in
                guard let self, let w, self.windows[w.id] === w else { return }
                AgentActivity.shared.windowChanged(w)
            }
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

    func closeWindow(_ w: AgentWindow, end: AgentTabRow.End = .done) {
        guard windows[w.id] != nil else { return }
        windows[w.id] = nil
        AgentActivity.shared.windowClosed(w, end)
        w.close()
        onEvent?("window-close \(w.id)")
        updateIndicator()
    }

    private func closeIdleWindows() {
        for w in windows.values where w.ownerKey.hasPrefix("http-") && Date().timeIntervalSince(w.lastUsed) > 900 { closeWindow(w) }
    }

    func withWindow(_ a: [String: Any], _ s: AgentSession, _ done: @escaping (AgentResult) -> Void, _ body: (AgentWindow) -> Void) {
        if case .failure(let why) = session(s) { return done(.error(why.text)) }
        // The person took this window's page (Take over): say so, once per window, instead of acting elsewhere.
        if let asked = (a["window"] as? Int) ?? s.currentWindow, let note = takenOver[asked], note.owner == s.ownerKey {
            if windows[asked] == nil || !note.told {
                takenOver[asked]?.told = true
                if windows[asked] == nil, s.currentWindow == asked { s.currentWindow = nil }
                return done(.error(note.message))
            }
        }
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

    // MARK: Saved logins (fill only)

    /// The engine's saved-login rows for agent pages, by tab, as they arrive (never a password: username and site).
    private(set) var loginRows: [ObjectIdentifier: (rows: [[String: String]], at: Date)] = [:]
    private var autofillObserved = false

    /// Agent pages' saved-login rows come here instead of a window's list (nobody would see one).
    private func observeAutofill() {
        #if canImport(AircCore)
        guard !autofillObserved, let chromium = app?.engine as? ChromiumEngine else { return }
        autofillObserved = true
        let previous = chromium.autofillSuggestionsDidChange
        chromium.autofillSuggestionsDidChange = { [weak self] page, items in
            if let self, self.isAgentTab(page) {
                let key = ObjectIdentifier(page)
                // The first arrival's time counts: the engine ignores a choice in the rows' first 500 ms.
                if items.isEmpty { self.loginRows[key] = nil } else { self.loginRows[key] = (items, self.loginRows[key]?.at ?? Date()) }
                return
            }
            previous?(page, items)
        }
        #endif
    }

    func clearLoginRows(_ tab: EngineTab) { loginRows[ObjectIdentifier(tab)] = nil }

    // MARK: The log (metadata only, never content)

    func log(_ entry: [String: Any]) {
        var e = entry
        e["t"] = ISO8601DateFormatter().string(from: Date())
        let file = logFile
        logQueue.async {
            guard var data = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return }
            data.append(0x0A)
            _ = AgentPaths.writePrivate(data, to: file.path, append: true)
        }
    }

    func logCall(_ tool: String, _ s: AgentSession, _ result: AgentResult, _ ms: Double) {
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
    func updateIndicator() {
        let busy = !live.isEmpty || !windows.isEmpty
        if busy != badgeShown { NSApp.dockTile.badgeLabel = busy ? "✦" : nil }
        changed()
    }

    var badgeShown: Bool { NSApp.dockTile.badgeLabel == "✦" }

    /// The connected apps' names, for the Dock menu and Settings.
    var connectedNames: [String] { Array(Set(live.values.map { $0.clientName ?? $0.client })).sorted() }

    /// Dock menu › Agents: who is connected, Stop Agents, Settings.
    func addDockItems(to menu: NSMenu) {
        guard launched else { return }
        let item = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Agents")
        let status: String
        if !live.isEmpty {
            status = "\(connectedNames.joined(separator: ", ")) · \(windows.count) window\(windows.count == 1 ? "" : "s")"
        } else {
            status = isOn ? "On, no app connected" : "Off"
        }
        let head = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        head.isEnabled = false
        sub.addItem(head)
        let stop = AgentMenuItem("Stop Agents") { [weak self] in self?.stopAgents(reason: "person") }
        stop.isEnabled = !live.isEmpty || !windows.isEmpty
        sub.addItem(stop)
        sub.addItem(.separator())
        sub.addItem(AgentMenuItem("Agents Settings…") { [weak self] in
            self?.app?.showSettings(page: .agents)
            NSApp.activate(ignoringOtherApps: true)
        })
        item.submenu = sub
        // First, so the menu's own items keep their places (Little Arc's stay last).
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }
}

/// An app the person answered: allowed or not, remembered per app.
struct AgentClient: Codable, Identifiable, Equatable {
    var key: String
    var name: String
    var detail: String
    var allowed: Bool
    var decided: Date
    var lastUsed: Date?
    /// The person pressed Stop for this app (the Agents folder): it's refused until they allow it again.
    var stopped: Bool?
    var id: String { key }
}

extension JSONEncoder {
    static var agents: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var agents: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
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
