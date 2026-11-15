// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AppKit
import AircKit

/// The social studio's sequences (tools/social), next to the homepage loop (AgentsDemo.run). All are scripted runs of
/// the real app on synthetic pages served on 127.0.0.1, written as frames plus capture.json ({frames: [{file, hold}],
/// size}) to <snapshot dir>/agents-<mode>/:
///
/// - `--agent-demo=hero` (20–40 s): the person's window, signed in to the bakery "Pastelaria Aurora"; Airc asks
///   "Allow ‘Claude’…?"; the sidebar's Agents folder lights up with "Claude · Pastelaria Aurora", its dot pulsing, and
///   the start banner; Watch shows Claude ordering (pointer, ringed clicks, the outlined field, captions such as
///   "Clicking ‘Order again’", "Typing in ‘Pickup time’"); the person takes the order page over as their own tab; then
///   stops Claude. Frames are the browser window as drawn (Watch's own picture composited over the page card).
/// - `--agent-demo=setup`: Settings › Agents › Add to Claude Desktop, the question, Add, and the config it wrote. Every
///   write goes to a scratch home in the snapshot folder (AgentSetup.homeOverride); the run refuses to start unless the
///   config path is inside it, and checks the account's real Claude config is unchanged.
/// - `--agent-demo=login` (Chromium): Claude on a synthetic sign-in page reads it (read_page: the password field
///   "(hidden)"), clicks the email field and calls fill_saved_login; Airc fills the person's saved login in the page, and
///   a second read still shows the password hidden. Frames as the loop's: the conversation beside the agent window.
extension AgentsDemo {
    var c: WindowController { runner.c }

    private func reset() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        frames = []
    }

    private func after(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }

    /// A frame of the browser window as the person sees it: the window's capture (the shown page from the engine),
    /// Watch's own render over the page card while it's open, and `overlay` (the approval question) at the top right.
    func windowFrame(hold: Double, overlay: CGImage? = nil, _ then: @escaping () -> Void) {
        let raw = "_raw-" + UUID().uuidString.prefix(8)
        let watch = c.sidebar.agents.watch.flatMap { MarketingAgentsState.render($0) }
        let card = c.card.frame, root = c.root.bounds.size
        runner.captureNow(raw) { [self] in
            let url = runner.dir.appendingPathComponent(raw + ".png")
            defer { try? FileManager.default.removeItem(at: url) }
            guard let base = (try? Data(contentsOf: url)).flatMap(NSBitmapImageRep.init(data:)),
                  let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide, pixelsHigh: base.pixelsHigh, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: out) else { runner.note("demo: no window capture"); return then() }
            let s = CGFloat(base.pixelsWide) / root.width
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            base.draw(in: NSRect(x: 0, y: 0, width: out.pixelsWide, height: out.pixelsHigh))
            if let watch {
                let r = NSRect(x: card.minX * s, y: (root.height - card.maxY) * s, width: card.width * s, height: card.height * s)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: r, xRadius: AircMetrics.Window.cardRadius * s, yRadius: AircMetrics.Window.cardRadius * s).addClip()
                watch.draw(in: r)
                NSGraphicsContext.restoreGraphicsState()
            }
            if let overlay {
                let w = CGFloat(overlay.width), h = CGFloat(overlay.height)
                let k = min(1, (CGFloat(out.pixelsWide) * 0.34) / w)
                let r = NSRect(x: CGFloat(out.pixelsWide) - w * k - 24 * s, y: CGFloat(out.pixelsHigh) - h * k - 24 * s, width: w * k, height: h * k)
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
                NSGraphicsContext.saveGraphicsState(); shadow.set()
                NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 14 * s, yRadius: 14 * s).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: r, xRadius: 14 * s, yRadius: 14 * s).addClip()
                ctx.cgContext.draw(overlay, in: r)
                NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.restoreGraphicsState()
            appendFrame(out, hold: hold)
            then()
        }
    }

    func appendFrame(_ rep: NSBitmapImageRep, hold: Double) {
        let name = String(format: "frame-%03d.png", frames.count)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: dir.appendingPathComponent(name)) }
        frames.append(["file": name, "hold": hold, "width": rep.pixelsWide, "height": rep.pixelsHigh])
    }

    /// find_element by visible name, then a left click at its centre.
    private func click(_ k: SpikeMCPClient, _ text: String, _ then: @escaping () -> Void) {
        k.call("find_element", ["text": text]) { r, _ in
            let line = SpikeMCPClient.text(r).components(separatedBy: "\n").first { $0.hasPrefix("[") } ?? "[]"
            let m = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [[String: Any]])?.first
            k.call("left_click", ["coordinate": [m?["x"] as? Int ?? 0, m?["y"] as? Int ?? 0]]) { _, _ in then() }
        }
    }

    private func check(_ ok: Bool, _ what: String) { spike.check(ok, "demo \(AgentsDemo.mode ?? ""): " + what) }

    // MARK: Hero

    func hero(_ done: @escaping () -> Void) {
        reset()
        AgentWatchView.ignoresOcclusion = true   // frames for the recording, whatever covers the window
        c.window.setContentSize(NSSize(width: 1440, height: 900))
        c.root.layoutSubtreeIfNeeded()
        let base = spike.base
        let claude = spike.helper(spike.app.store.defaultProfile.name, client: "Claude")
        spike.extra.append(claude)
        let folder = c.sidebar.agents
        var approval: CGImage?
        // The person's own window: the bakery's account page (signed in), no leftover "Save password?" from signing in.
        c.prompts.withdraw { _ in true }
        if let id = c.shownTabID, let page = c.engineTab(for: id), let url = URL(string: "\(base)/bakery/account") { page.load(url) }
        after(2.0) { [self] in
        spike.personState = (spike.app.controllers.count, c.shownTabID, spike.personPage()?.url?.absoluteString)
        windowFrame(hold: 1.8) { [self] in
            spike.poll({ AgentCenter.shared.approvals.shown != nil }, timeout: 6) { asked in
                if asked { approval = AgentCenter.shared.approvals.shown?.picture()?.cgImage }
            }
            spike.connect(claude, answer: .allow) { [self] ok, _ in
                check(ok, "Claude connects after Allow")
                windowFrame(hold: 1.8, overlay: approval) { [self] in
                    claude.call("open_window", ["url": "\(base)/bakery/account"]) { [self] r, _ in
                        let window = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                        spike.poll({ folder.model.items.contains { $0.window == window && $0.label == "Claude · Pastelaria Aurora" } && !c.toast.isHidden }, timeout: 6) { [self] lit in
                            check(lit, "the Agents folder lights up with “Claude · Pastelaria Aurora” and the banner (\(folder.model.items.map(\.label)), toast \(c.toast.shownText ?? "-"))")
                            claude.call("wait", ["duration": 0.9]) { _, _ in }
                            after(0.3) { [self] in
                                check(AgentPulseDot.pulsing.count > 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "the dot pulses while Claude works")
                                windowFrame(hold: 2.2) { [self] in watchPart(claude, folder, window, done) }
                            }
                        }
                    }
                }
            }
        }
        }
    }

    private func watchPart(_ claude: SpikeMCPClient, _ folder: SidebarAgentsView, _ window: Int, _ done: @escaping () -> Void) {
        guard let row = AgentActivity.shared.model.rows.first(where: { $0.window == window }) else { check(false, "a row to watch"); return done() }
        after(1.2) { [self] in
            folder.openWatch(row.id)
            spike.poll({ (folder.watch?.framesShown ?? 0) >= 3 }, timeout: 4) { [self] watching in
                check(watching, "Watch shows Claude's page live")
                windowFrame(hold: 1.4) { [self] in
                    // Each step: the call, a moment for the caption and the pointer, the frame.
                    var steps: [(String, String?, Double, Double)] = [   // (element, text to type, settle, hold)
                        ("Order again", nil, 0.25, 1.6), ("Pickup time", "9:30", 0.2, 1.7), ("Note for the bakery", "Less sugar, please", 0.2, 1.7),
                        ("Place order", nil, 0.25, 1.5),
                    ]
                    var captions: [String] = []
                    func next() {
                        guard !steps.isEmpty else { return ordered() }
                        let (element, text, settle, hold) = steps.removeFirst()
                        click(claude, element) { [self] in
                            let frameNow = { self.after(settle) { captions.append(folder.watch?.caption ?? ""); self.windowFrame(hold: hold) { self.after(0.6, next) } } }
                            if let text { claude.call("type", ["text": text]) { _, _ in frameNow() } } else { frameNow() }
                        }
                    }
                    func ordered() {
                        check(captions.contains { $0.hasPrefix("Clicking") } && captions.contains("Typing in ‘Pickup time’"), "Watch's captions name what Claude does (\(captions))")
                        check(!captions.joined().contains("9:30") && !captions.joined().contains("Less sugar"), "no caption shows typed text")
                        after(1.6) { [self] in
                            windowFrame(hold: 1.6) { [self] in takeOverPart(claude, folder, window, row.id, done) }
                        }
                    }
                    next()
                }
            }
        }
    }

    private func takeOverPart(_ claude: SpikeMCPClient, _ folder: SidebarAgentsView, _ window: Int, _ orderRow: String, _ done: @escaping () -> Void) {
        // Claude goes on in a second tab; the person takes the placed order over as their own tab.
        claude.call("open_tab", ["url": "\(spike.base)/bakery/account"]) { [self] _, _ in
            after(0.8) { [self] in
                folder.watch?.takeOver()
                spike.poll({ AgentActivity.shared.model.row(orderRow)?.end == .takenOver }, timeout: 4) { [self] took in
                    let shown = c.shownTabID.flatMap { c.store.tab($0)?.url } ?? ""
                    check(took && shown.contains("/bakery/done"), "Take over: the order page is the person's tab (\(shown))")
                    // The person's own action: their window's state from here on (agentspike's end check).
                    spike.personState = (spike.app.controllers.count, c.shownTabID, spike.personPage()?.url?.absoluteString)
                    after(0.8) { [self] in
                        windowFrame(hold: 2.4) { [self] in
                            guard let other = AgentActivity.shared.model.rows.first(where: { $0.window == window && $0.isLive }) else {
                                check(false, "Claude's other tab is in the folder"); return finish(claude, done)
                            }
                            folder.stop(other.id)
                            spike.poll({ AgentCenter.shared.windows.isEmpty }, timeout: 4) { [self] stopped in
                                check(stopped && folder.model.items.contains { $0.status == "Stopped" }, "Stop ends Claude's work and its row says Stopped")
                                after(0.6) { [self] in windowFrame(hold: 3.0) { [self] in finish(claude, done) } }
                            }
                        }
                    }
                }
            }
        }
    }

    private func finish(_ claude: SpikeMCPClient, _ done: @escaping () -> Void) {
        write()
        let total = frames.reduce(0.0) { $0 + ($1["hold"] as? Double ?? 0) }
        if AgentsDemo.mode == "hero" { check(total >= 20 && total <= 40, "the hero sequence runs 20–40 s (\(total) s)") }
        if let k = (AgentCenter.shared.settings.clients.first { $0.name == "Claude" })?.key { AgentCenter.shared.allowAgain(k) }
        AgentWatchView.ignoresOcclusion = false
        claude.stop()
        done()
    }

    // MARK: Setup (Add to Claude Desktop, in a scratch home)

    /// The clip's steps and the app's state at each (the agentspike end check asserts Airc never became active).
    private func trace(_ step: String) {
        runner.note("demo setup trace: \(step): active \(NSApp.isActive), key \(NSApp.keyWindow?.title ?? "none"), front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
    }

    func setupClip(_ done: @escaping () -> Void) {
        reset()
        let watcher = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.runner.note("demo setup trace: BECAME ACTIVE \(Thread.callStackSymbols.prefix(14).joined(separator: " | "))")
        }
        _ = watcher
        let fm = FileManager.default
        let sandbox = dir.appendingPathComponent("home", isDirectory: true)
        let config = AgentSetup.claudeDesktopConfig(home: sandbox)
        let realConfig = AgentSetup.claudeDesktopConfig(home: fm.homeDirectoryForCurrentUser)
        let realBefore = try? Data(contentsOf: realConfig)
        try? fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Claude Desktop's file as someone with one other server has it.
        let existing = #"{"mcpServers":{"files":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","~/Documents"]}}}"#
        try? Data(existing.utf8).write(to: config)
        AgentSetup.homeOverride = sandbox
        let target = AgentSetup.claudeDesktopConfig(home: AgentSetup.home)
        guard target.standardizedFileURL.path.hasPrefix(sandbox.standardizedFileURL.path + "/"), target != realConfig else {
            AgentSetup.homeOverride = nil
            check(false, "the setup clip writes only into its scratch home (refused: \(target.path))")
            return done()
        }
        check(true, "the setup clip writes only into its scratch home")
        spike.personState = (spike.app.controllers.count, c.shownTabID, spike.personPage()?.url?.absoluteString)
        trace("before Settings")
        spike.app.showSettings(page: .agents)
        trace("Settings shown")
        guard let w = spike.app.settingsWindow?.window else { check(false, "Settings › Agents opens"); return done() }
        // Off screen and no taller than the screen: a window macOS has to pull back on screen comes forward with its
        // sheet and activates Airc (seen at 1100 pt).
        w.setContentSize(NSSize(width: 780, height: 1000))
        w.setFrameOrigin(NSPoint(x: -6000, y: 200))
        after(1.0) { [self] in
            scrollToEnd(w.contentView)
            after(0.3) { [self] in
                settingsFrame(w, hold: 2.0)
                trace("first frame")
                AgentsSettingsModel.shared.addToClaudeDesktop(window: w)
                trace("asked")
                after(0.7) { [self] in
                    trace("sheet up")
                    let sheet = w.attachedSheet
                    check(sheet != nil, "Add to Claude Desktop asks first")
                    settingsFrame(w, hold: 2.4)
                    let add = sheet?.contentView.map(descendants)?.compactMap { $0 as? NSButton }.first { $0.title == "Add" }
                    add?.performClick(nil)
                    trace("Add pressed")
                    after(0.9) { [self] in
                        trace("after Add")
                        scrollToEnd(w.contentView)   // the result line under Set up, whole
                        settingsFrame(w, hold: 2.2)
                        let root = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                        let servers = root["mcpServers"] as? [String: Any] ?? [:]
                        let backups = ((try? fm.contentsOfDirectory(atPath: config.deletingLastPathComponent().path)) ?? []).filter { $0.contains(".airc-backup-") }
                        check(servers["airc"] != nil && servers["files"] != nil && !backups.isEmpty,
                              "the scratch config gains mcpServers.airc, keeps the other server, with a backup (\(servers.keys.sorted()), \(backups.count) backup)")
                        check((try? Data(contentsOf: realConfig)) == realBefore, "the account's real Claude config is untouched")
                        // The card shows the entry as on a person's Mac: the helper's stable link in the usual data folder,
                        // no test --data-dir, no paths of this build machine (the written file was checked above).
                        var shown = root
                        var servers2 = servers
                        servers2["airc"] = ["command": "~/Library/Application Support/Airc/bin/airc-mcp", "args": ["--client", "claude-desktop"]]
                        shown["mcpServers"] = servers2
                        let pretty = (try? JSONSerialization.data(withJSONObject: shown, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                            .map { String(decoding: $0, as: UTF8.self) } ?? ""
                        check(!pretty.contains("/Users/") && !pretty.contains(NSHomeDirectory()), "the clip's config card shows no paths of this Mac")
                        configFrame(w, pretty, hold: 3.0)
                        AgentSetup.homeOverride = nil
                        trace("before close")
                        w.close()
                        trace("closed")
                        write()
                        done()
                    }
                }
            }
        }
    }

    private func descendants(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descendants) }

    private func scrollToEnd(_ v: NSView?) {
        guard let v else { return }
        for s in descendants(v).compactMap({ $0 as? NSScrollView }) {
            guard let doc = s.documentView else { continue }
            let y = doc.isFlipped ? max(0, doc.bounds.height - s.contentView.bounds.height) : 0
            s.contentView.scroll(to: NSPoint(x: 0, y: y))
            s.reflectScrolledClipView(s.contentView)
        }
    }

    /// Settings' window as drawn, its sheet (the question) dropped from the top, on the studio's paper.
    private func settingsFrame(_ w: NSWindow, hold: Double, extra: ((NSRect, CGFloat) -> Void)? = nil) {
        guard let page = runner.mkContentImage(w) else { return runner.note("demo: no Settings picture") }
        let sheet = w.attachedSheet.flatMap { runner.mkContentImage($0) }
        let s: CGFloat = 2, pad: CGFloat = 60
        let wide = extra == nil ? page.size.width : page.size.width + 560
        let size = NSSize(width: (wide + pad * 2) * s, height: (page.size.height + pad * 2) * s)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.95, blue: 0.91, alpha: 1), NSColor(srgbRed: 0.96, green: 0.93, blue: 0.97, alpha: 1)])!
            .draw(in: NSRect(origin: .zero, size: size), angle: -35)
        let r = NSRect(x: pad * s, y: pad * s, width: page.size.width * s, height: page.size.height * s)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor.white.setFill(); NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).addClip()
        page.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        if let sheet {
            let sr = NSRect(x: r.midX - sheet.size.width * s / 2, y: r.maxY - sheet.size.height * s - 40 * s, width: sheet.size.width * s, height: sheet.size.height * s)
            NSGraphicsContext.saveGraphicsState(); shadow.set()
            NSColor.white.setFill(); NSBezierPath(roundedRect: sr, xRadius: 24, yRadius: 24).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: sr, xRadius: 24, yRadius: 24).addClip()
            sheet.draw(in: sr)
            NSGraphicsContext.restoreGraphicsState()
        }
        extra?(r, s)
        NSGraphicsContext.restoreGraphicsState()
        appendFrame(rep, hold: hold)
    }

    /// The last setup frame: Settings beside the file Airc wrote (the scratch copy, its path shown as ~).
    private func configFrame(_ w: NSWindow, _ json: String, hold: Double) {
        settingsFrame(w, hold: hold) { r, s in
            let card = NSRect(x: r.maxX + 40 * s, y: r.minY + 80 * s, width: 500 * s, height: r.height - 160 * s)
            NSColor.white.setFill(); NSBezierPath(roundedRect: card, xRadius: 20, yRadius: 20).fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15 * s, weight: .semibold), .foregroundColor: AgentsDemo.ink]
            ("claude_desktop_config.json" as NSString).draw(at: NSPoint(x: card.minX + 24 * s, y: card.maxY - 42 * s), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11 * s, weight: .regular), .foregroundColor: AgentsDemo.ink2]
            (json as NSString).draw(with: NSRect(x: card.minX + 24 * s, y: card.minY + 20 * s, width: card.width - 48 * s, height: card.height - 80 * s),
                                    options: [.usesLineFragmentOrigin], attributes: body)
        }
    }

    // MARK: Login (fill_saved_login, read_page masks the password)

    static let shopLogin = """
    <!doctype html><title>Sign in · Pastelaria Aurora</title>\(style)<header><b>Pastelaria Aurora</b><span>Sign in</span></header>
    <main><h1>Sign in</h1><p class="muted">to order ahead and skip the queue</p>
    <form method="post" action="/login"><label>Email<input id="u" name="username" autocomplete="username" placeholder="you@example.com"></label>
    <label>Password<input id="p" name="password" type="password" autocomplete="current-password" placeholder="Password"></label>
    <button class="btn" id="go">Sign in</button></form></main>
    """

    func loginClip(_ done: @escaping () -> Void) {
        reset()
        guard spike.engine == "chromium" else {
            spike.note("FAIL-ENV agentspike demo login: saved logins fill on the Chromium engine only (this run: \(spike.engine))")
            return done()
        }
        // The person's saved login (they sign in once in their own window, and save it at Chromium's prompt).
        spike.personSignsIn { [self] saved in
            check(saved, "the person's login is saved")
            spike.personState = (spike.app.controllers.count, c.shownTabID, spike.personPage()?.url?.absoluteString)
            spike.demoPages = { r in r.method == "GET" && r.path == "/shop/login" ? LocalPageServer.Page(body: AgentsDemo.shopLogin) : nil }
            let claude = spike.helper(spike.app.store.defaultProfile.name, client: "Claude")
            spike.extra.append(claude)
            chat = [Line(kind: .person, text: "Sign me in to Pastelaria Aurora with my saved login.")]
            var shot: CGImage?
            var said = ""
            func snap(_ hold: Double, _ then: @escaping () -> Void) {
                claude.call("screenshot") { r, _ in shot = SpikeMCPClient.image(r) ?? shot; self.frame(shot, hold: hold); then() }
            }
            spike.connect(claude, answer: .allow) { [self] ok, _ in
                check(ok, "Claude connects")
                claude.call("open_window", ["url": "\(spike.base)/shop/login"]) { [self] _, _ in
                    chat.append(Line(kind: .tool, text: "open_window", detail: "Pastelaria Aurora · Sign in"))
                    snap(1.6) { [self] in
                        claude.call("read_page", ["mode": "outline"]) { [self] r, _ in
                            let out = SpikeMCPClient.text(r)
                            said += out
                            check(out.contains("(hidden)") || !out.contains(spike.loginPassword), "read_page: the empty password field reads as no value")
                            chat.append(Line(kind: .tool, text: "read_page", detail: "Email, Password, Sign in"))
                            snap(1.8) { [self] in
                                click(claude, "Email") { [self] in
                                    claude.call("fill_saved_login") { [self] r, _ in
                                        said += SpikeMCPClient.text(r)
                                        let user = SpikeMCPClient.json(r)["username"] as? String ?? ""
                                        check(!SpikeMCPClient.isError(r) && user == "ada@example.test", "fill_saved_login fills the saved login (\(SpikeMCPClient.text(r).prefix(100)))")
                                        chat.append(Line(kind: .tool, text: "fill_saved_login", detail: "\(user) · filled by Airc"))
                                        after(0.5) { [self] in
                                            snap(2.2) { [self] in
                                                claude.call("read_page", ["mode": "outline"]) { [self] r, _ in
                                                    let out = SpikeMCPClient.text(r)
                                                    said += out
                                                    let masked = out.contains("(hidden)") && !out.contains(spike.loginPassword)
                                                    check(masked, "read_page shows the filled password field as (hidden)")
                                                    chat.append(Line(kind: .tool, text: "read_page", detail: "Password: (hidden)"))
                                                    frame(shot, hold: 2.4)
                                                    chat.append(Line(kind: .claude, text: "Your login is filled in. Airc filled the password itself: I only ever see it as (hidden)."))
                                                    frame(shot, hold: 3.2)
                                                    check(!said.contains(spike.loginPassword), "nothing Claude got back holds the password")
                                                    write()
                                                    claude.stop()
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
#endif
