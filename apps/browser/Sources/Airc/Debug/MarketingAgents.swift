// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AircDesign
import AppKit

/// The marketing shot of following an agent (Sidebar/SidebarAgents.swift, Sidebar/AgentWatchView.swift,
/// docs/user/agents.md), the marketing scenario's part "agents" (`scripts/marketing-shots.sh --parts agents`):
///   - agents-watch: the Studio Space, its sidebar's Agents folder with "Claude · Mailbox" (acting) and "Claude · Corner
///     Shop", and Watch over the page: Claude typing in Mailbox's search field, the field outlined, the pointer on it,
///     the caption "Typing in ‘Search mail’". Both sites are synthetic pages served on 127.0.0.1 (nothing in the shot
///     names the address); the client is agentspike's MCP test client, reporting itself as "Claude".
extension SnapshotRunner {
    func mkAgentsShots(_ d: MarketingDemo) {
        // The Studio Space (the person's profile) on Apple's design page, its selected tab, so no other page loads
        // (Wikipedia answers bursts of shot runs with its rate-limit page, which then names a sidebar row).
        mkShow(d, "studio", "hig")
        mkSettleShown()
        // command-bar-connect-claude: ⌘T "connect claude": Connect Claude and other AI apps… (Agent/AgentsConnect.swift).
        run { [self] in c.openCommandBar(mode: .newTab); c.commandBar?.type("connect claude") }
        wait(0.8)
        run { [self] in note("marketing: connect rows: " + (c.commandBar?.resultTitles.joined(separator: " | ") ?? "-")) }
        mkWindowShot("command-bar-connect-claude")
        run { [self] in c.closeCommandBar() }
        wait(0.4)
        let state = MarketingAgentsState()
        run { AgentWatchView.ignoresOcclusion = true }
        step { [self] done in
            state.server = LocalPageServer(responses: [
                "/mail.html": LocalPageServer.Page(body: MarketingAgentsState.mailPage),
                "/shop.html": LocalPageServer.Page(body: MarketingAgentsState.shopPage),
            ])
            state.server?.start { [self] port in
                guard let port else { note("marketing: MISSING agents-watch: no fixture server"); return done() }
                // The demo pages' own names when the marketing server runs (mailbox.aircbrowser.com: History and
                // Activity then read like a real site), else this loopback server.
                var base = "http://127.0.0.1:\(port)"
                if d.serverUp {
                    MarketingServer.extraPages["/agents/mail.html"] = MarketingAgentsState.mailPage
                    MarketingServer.extraPages["/agents/shop.html"] = MarketingAgentsState.shopPage
                    base = "http://mailbox.aircbrowser.com/agents"
                }
                let profile = c.store.profile(ofSpace: c.currentSpaceID)
                AgentCenter.shared.app = app
                AgentCenter.shared.enableForCheck(grants: [], http: false)
                // Airc asks once: the question is the agents-approval shot, then it's answered Allow.
                AgentCenter.shared.approvals.automatic = nil
                let spike = AgentSpike(runner: self)
                let k = SpikeMCPClient(helper: spike.helperPath, args: ["--data-dir", AppPaths.dataDirectory.path, "--client", "Claude",
                                                                        "--profile", profile.id])
                state.client = k
                guard k.start() else { note("marketing: MISSING agents-watch: the helper didn't start"); return done() }
                mkApprovalShot()
                k.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Claude", "version": "1"]]) { _ in
                    k.call("open_window", ["url": base.contains("aircbrowser") ? "http://cornershop.aircbrowser.com/agents/shop.html" : "\(base)/shop.html"]) { r, _ in
                        let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                        k.call("open_window", ["url": "\(base)/mail.html"]) { r, _ in
                            state.window = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                            _ = w
                            done()
                        }
                    }
                }
            }
        }
        wait(1.5)
        run { [self] in
            guard let row = AgentActivity.shared.model.rows.first(where: { $0.window == state.window }) else {
                return note("marketing: MISSING agents-watch: no Agents row")
            }
            c.sidebar.agents.openWatch(row.id)
        }
        wait(1.2)
        step { done in
            guard let k = state.client else { return done() }
            k.call("left_click", ["coordinate": [444, 37], "window": state.window]) { _, _ in
                k.call("type", ["text": "flight to Lisbon", "window": state.window]) { _, _ in done() }
            }
        }
        wait(0.35)
        step { [self] done in
            // Watch's picture is a layer's contents, which the window capture doesn't draw: its own render goes over
            // the card.
            guard let watch = c.sidebar.agents.watch, let image = MarketingAgentsState.render(watch) else {
                note("marketing: MISSING agents-watch: no Watch")
                return done()
            }
            let card = c.card.frame, rootHeight = c.root.bounds.height
            mkWindowImage { img in
                guard let img else { self.note("marketing: MISSING agents-watch: no capture"); return done() }
                let size = self.c.root.bounds.size
                let (canvas, origin) = MarketingStudio.canvas(around: size)
                let frame = NSRect(origin: origin, size: size)
                let window = MarketingStudio.Layer(image: img, frame: frame, dark: self.mkIsDark(), lights: self.mkLights(self.c.window))
                let over = MarketingStudio.Layer(image: image, frame: NSRect(x: frame.minX + card.minX, y: frame.minY + rootHeight - card.maxY,
                                                                              width: card.width, height: card.height),
                                                 radius: AircMetrics.Window.cardRadius, shadow: .none)
                self.mkWrite("agents-watch", canvas: canvas, dark: false, [window, over])
                done()
            }
        }
        // A little more work for the Activity history, then the client leaves (its rows say Done).
        step { done in
            guard let k = state.client else { return done() }
            k.call("left_click", ["coordinate": [600, 37], "window": state.window]) { _, _ in
                k.call("read_page", ["window": state.window]) { _, _ in done() }
            }
        }
        run { [self] in
            c.sidebar.agents.closeWatch()
            state.client?.stop()
            AgentActivity.shared.saveNow()
        }
        wait(1.0)
        mkAgentsSettingsShots()
        run { [self] in
            state.server?.stop()
            AgentCenter.shared.stopAgents(reason: "marketing", off: true)
            AgentWatchView.ignoresOcclusion = false
        }
        wait(0.6)
        mkAgentPanelShot(d)   // agentpanel: the Airc Agent asking before it pays (MarketingAgentPanel.swift)
        mkAgentPaneShots(d)   // agentux: the agent pane in the window, M1/M2/M3 B, light and dark (MarketingAgentPane.swift)
    }

    /// agents-approval: "Allow ‘Claude’ to use Airc?" as Airc shows it (its own picture), on the studio's desktop.
    private func mkApprovalShot() {
        func attempt(_ left: Int) {
            guard let panel = AgentCenter.shared.approvals.shown else {
                if left > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt(left - 1) } }
                else { note("marketing: MISSING agents-approval: Airc didn't ask") }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                if let rep = panel.picture() {
                    let image = NSImage(size: rep.size)
                    image.addRepresentation(rep)
                    let (canvas, origin) = MarketingStudio.canvas(around: rep.size)
                    mkWrite("agents-approval", canvas: canvas, dark: false, [
                        MarketingStudio.Layer(image: image, frame: NSRect(origin: origin, size: rep.size), radius: 16, shadow: .panel),
                    ])
                } else {
                    note("marketing: MISSING agents-approval: no picture of the question")
                }
                panel.answer(.allow)
            }
        }
        attempt(60)
    }

    /// settings-agents (the top: the switch, Show agent pages in front, the app) and settings-agents-activity (scrolled
    /// to Activity: what Claude did, by site and kind, never content).
    private func mkAgentsSettingsShots() {
        run { [self] in
            NSApp.appearance = NSAppearance(named: .aqua)
            c.app?.showSettings(page: .agents)
            if let w = c.app?.settingsWindow?.window {
                w.setContentSize(NSSize(width: 780, height: 1180))
                w.setFrameOrigin(NSPoint(x: -6000, y: 200))
            }
        }
        wait(1.0)
        for (name, end) in [("settings-agents", false), ("settings-agents-activity", true)] {
            step { [self] done in
                defer { done() }
                guard let w = c.app?.settingsWindow?.window, let view = w.contentView else { return note("marketing: MISSING \(name): no Settings window") }
                if end {
                    func all(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(all) }
                    for s in all(view).compactMap({ $0 as? NSScrollView }) {
                        guard let doc = s.documentView else { continue }
                        s.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? max(0, doc.bounds.height - s.contentView.bounds.height) : 0))
                        s.reflectScrolledClipView(s.contentView)
                    }
                }
                guard let img = mkContentImage(w) else { return note("marketing: MISSING \(name): no picture") }
                let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
                mkWrite(name, canvas: canvas, dark: false, [
                    MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w)),
                ])
            }
        }
        // settings-agents-devices: Other devices on, listening on the tailnet, a pairing code with its command, and two
        // paired devices. Made-up addresses, Mac name and device names; nothing listens (stageRemoteForMarketing).
        run {
            let now = Date()
            AgentCenter.shared.stageRemoteForMarketing((addresses: ["100.101.102.103", "fd7a:115c:a1e0::1234"], host: "my-mac.tailnet-a1b2.ts.net",
                                                        devices: [(name: "studio-mini", paired: now.addingTimeInterval(-6 * 86_400), used: now.addingTimeInterval(-25 * 60), address: "100.88.12.40"),
                                                                  (name: "travel-laptop", paired: now.addingTimeInterval(-2 * 86_400), used: now.addingTimeInterval(-3 * 3600), address: "100.90.7.21")]))
            AgentsSettingsModel.shared.startPairing()
        }
        wait(0.6)
        run { [self] in c.app?.settingsWindow?.model.reveal("Other devices") }
        wait(0.8)
        step { [self] done in
            defer { done() }
            guard let w = c.app?.settingsWindow?.window, let view = w.contentView else { return note("marketing: MISSING settings-agents-devices: no Settings window") }
            guard let img = mkContentImage(w) else { return note("marketing: MISSING settings-agents-devices: no picture") }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("settings-agents-devices", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w)),
            ])
        }
        run {
            AgentsSettingsModel.shared.cancelPairing()
            AgentCenter.shared.stageRemoteForMarketing(nil)
        }
        run { [self] in c.app?.settingsWindow?.window.close() }
        wait(0.4)
    }
}

final class MarketingAgentsState {
    var server: LocalPageServer?
    var client: SpikeMCPClient?
    var window = 0

    /// A view's layers (contents included: Watch's page picture) as an image, the right way up.
    static func render(_ v: NSView) -> NSImage? {
        let size = v.bounds.size, scale: CGFloat = 2
        guard size.width > 0, let layer = v.layer,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if v.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        return ctx.makeImage().map { NSImage(cgImage: $0, size: size) }
    }

    static let mailPage = """
    <!doctype html><html><head><title>Inbox - Mailbox</title><style>
    *{box-sizing:border-box}body{margin:0;font:14px -apple-system,sans-serif;color:#1d2433;background:#f6f7f9;display:flex;height:100vh}
    nav{width:210px;background:#eef1f5;padding:18px 14px}nav b{display:block;font-size:19px;margin:0 6px 18px;color:#1f7a4d}
    nav a{display:block;padding:8px 10px;border-radius:8px;color:#394150;text-decoration:none}nav a.on{background:#dfe8e3;color:#1f5f3d;font-weight:600}
    input,button{font:inherit}main{flex:1;padding:18px 24px}#q{width:420px;height:38px;border:1px solid #cfd6df;border-radius:10px;padding:0 14px;font:14px -apple-system;background:#fff}
    .bar{display:flex;gap:10px;align-items:center;margin-bottom:16px}button{height:38px;padding:0 16px;border-radius:10px;border:1px solid #cfd6df;background:#fff;font:14px -apple-system}
    .m{display:flex;gap:14px;padding:14px 16px;background:#fff;border-radius:12px;margin-bottom:8px;box-shadow:0 1px 0 #e6e9ee}
    .m .f{width:150px;font-weight:600}.m .s{flex:1;color:#5b6474}.m .t{color:#8a93a3;font-size:12px}
    </style></head><body><nav><b>Mailbox</b><a class="on">Inbox</a><a>Starred</a><a>Sent</a><a>Archive</a></nav>
    <main><div class="bar"><input id="q" aria-label="Search mail" placeholder="Search mail"><button>Archive</button><button>Mark read</button></div>
    <div class="m"><span class="f">Lisbon Air</span><span class="s">Your booking is confirmed: Thursday, 08:40</span><span class="t">9:12</span></div>
    <div class="m"><span class="f">Corner Shop</span><span class="s">Your order is on its way</span><span class="t">8:05</span></div>
    <div class="m"><span class="f">Ada</span><span class="s">Lunch on Friday?</span><span class="t">Yesterday</span></div>
    <div class="m"><span class="f">City Library</span><span class="s">Two books are due next week</span><span class="t">Mon</span></div>
    <div class="m"><span class="f">Studio Team</span><span class="s">Notes from the design review</span><span class="t">Sun</span></div>
    </main></body></html>
    """
    static let shopPage = """
    <!doctype html><html><head><title>Cart - Corner Shop</title><style>
    body{margin:0;font:15px -apple-system,sans-serif}header{height:64px;background:#7a3b1f;color:#fff;display:flex;align-items:center;padding:0 22px;font-size:20px;font-weight:600}
    </style></head><body><header>Corner Shop</header><p style="padding:20px">Sourdough loaf · 1</p></body></html>
    """
}
#endif
