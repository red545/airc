// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import SwiftUI

/// agent-pane, agent-pane-approval, agent-pane-connect (part "agents", each also "-dark"): the Airc Agent pane in the
/// window (docs/design/agent-ux.md M1, M2, M3 B) on a synthetic Corner Shop. The model is the scripted fake from
/// AgentPanelCheck.swift on loopback with a made-up key in memory; nothing reaches a real provider.
extension SnapshotRunner {
    func mkAgentPaneShots(_ d: MarketingDemo) {
        let fake = FakeModelServer()
        var server: LocalPageServer?
        var shop = ""
        var model = ""
        var appearanceBefore: Appearance?
        step { [self] done in
            let s = LocalPageServer(responses: [:])
            let home = "<title>Corner Shop</title><body style=\"font:16px -apple-system,sans-serif;margin:24px\"><h1>Corner Shop</h1><p>Your orders · Sourdough loaf · Oat milk</p></body>"
            s?.requestHandler = { r in
                if r.method == "POST", r.path == "/v1/messages" { return fake.answer(r) }
                if r.path == "/checkout.html" { return LocalPageServer.Page(body: AgentPanelCheck.shop) }
                return r.path == "/orders.html" ? LocalPageServer.Page(body: home) : nil
            }
            server = s
            s?.start { [self] port in
                guard let port else { note("marketing: MISSING agent-pane: no fixture server"); return done() }
                let loop = "http://127.0.0.1:\(port)"
                shop = loop
                model = loop
                if d.serverUp {
                    MarketingServer.extraPages["/agents/checkout.html"] = AgentPanelCheck.shop
                    MarketingServer.extraPages["/agents/orders.html"] = home
                    shop = "http://cornershop.aircbrowser.com/agents"
                }
                AgentCenter.shared.app = app
                AgentUI.forcedForTesting = true
                // The first-run card shows every provider not set up: no real Claude Code or Codex is looked at.
                let none = FileManager.default.temporaryDirectory.appendingPathComponent("airc-shotcli-\(getpid())", isDirectory: true)
                try? FileManager.default.createDirectory(at: none, withIntermediateDirectories: true)
                AgentCLIDetector.shared.setDirForTesting(none.path)
                AgentModelSettings.shared.update { $0.backend = .apiKey }
                AgentWatchView.ignoresOcclusion = true   // copies, which a recording can draw
                AgentModelSettings.shared.setTestKey("airc-marketing-made-up-key", provider: .anthropic, base: loop)
                done()
            }
        }
        for dark in [false, true] {
            let sfx = dark ? "-dark" : ""
            run { [self] in
                // The dark set is a dark Space, as quote-copy's (the window's theme decides the pane's colours).
                if dark { appearanceBefore = c.store.space(c.currentSpaceID)?.theme.appearance }
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                if dark { try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = .dark } }
                c.reloadAll(animated: false)
            }
            wait(0.8)
            // The Airc Agent button in the bottom bar, with its one-time hint.
            step { [self] done in
                AgentModelSettings.shared.setTestKey(nil, provider: .anthropic, base: nil)
                AgentRunCenter.shared.newConversation()
                AgentUI.close(c)
                done()
            }
            wait(0.5)
            mkWindowShot("agent-button" + sfx, dark: dark) { [self] frame in mkAgentHintLayer(frame, dark: dark) }
            // M3 B: nothing connected.
            step { [self] done in
                AgentModelSettings.shared.setTestKey(nil, provider: .anthropic, base: nil)
                AgentRunCenter.shared.newConversation()
                AgentPaneController.show(c)
                done()
            }
            wait(0.6)
            mkWindowShot("agent-pane-connect" + sfx, dark: dark)
            // M1: running, with the live page card.
            step { [self] done in
                AgentModelSettings.shared.setTestKey("airc-marketing-made-up-key", provider: .anthropic, base: model)
                fake.begin("m1\(sfx)", [.tool("navigate", ["url": "\(shop)/orders.html"]), .tool("read_page", ["mode": "text"]),
                                        .tool("find_element", ["text": "Sourdough loaf"]), .toolThenHold("wait", ["duration": 20], hold: 0)])
                let p = AgentPaneController.show(c)
                p.model.text = "Reorder last week's groceries from Corner Shop, same quantities. Stop before paying."
                p.model.send()
                waitUntil({ AgentRunCenter.shared.steps.filter { $0.kind == .action }.count >= 4 }, timeout: 25) { done() }
            }
            wait(2.0)
            mkWindowShot("agent-pane" + sfx, dark: dark)
            // M2: waiting for the OK.
            step { [self] done in
                AgentRunCenter.shared.stop()
                AgentRunCenter.shared.newConversation()
                fake.begin("m2\(sfx)", [.tool("navigate", ["url": "\(shop)/checkout.html"]), .tool("find_element", ["text": "Pay"]),
                                        .tool("left_click", ["coordinate": [100, 180]]), .text("Ordered.")])
                let p = AgentPaneController.show(c)
                p.model.text = "Check out my Corner Shop cart"
                p.model.send()
                waitUntil({ AgentRunCenter.shared.approval != nil }, timeout: 25) { done() }
            }
            wait(1.0)
            mkWindowShot("agent-pane-approval" + sfx, dark: dark)
            run { [self] in
                AgentRunCenter.shared.answerApproval(allow: false)
                AgentRunCenter.shared.newConversation()
                AgentPaneController.pane(of: c)?.close()
            }
            wait(0.4)
        }
        run { [self] in
            NSApp.appearance = nil
            if let a = appearanceBefore { try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = a } }
            c.reloadAll(animated: false)
            AgentUI.forcedForTesting = nil
            AgentCLIDetector.shared.setDirForTesting(nil)
            AgentWatchView.ignoresOcclusion = false
            AgentModelSettings.shared.setTestKey(nil, provider: .anthropic, base: nil)
            MarketingServer.extraPages["/agents/checkout.html"] = nil
            MarketingServer.extraPages["/agents/orders.html"] = nil
            server?.stop()
        }
        wait(0.4)
    }

    /// The first-run hint as a card over the bottom bar's Airc Agent button (a popover draws in its own window, which
    /// the window capture doesn't hold).
    func mkAgentHintLayer(_ frame: NSRect, dark: Bool) -> [MarketingStudio.Layer] {
        let theme = c.currentPalette.resolved
        let host = NSHostingView(rootView: AgentButtonHintView(tryIt: {}, dismiss: {}).environment(\.aircTheme, theme).background(theme.surface.color))
        host.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        guard let img = render(host) else { return [] }
        let b = c.sidebar.footer.agentButton
        var r = b.convert(b.bounds, to: c.root)
        if c.root.isFlipped { r.origin.y = c.root.bounds.height - r.maxY }
        let size = host.frame.size
        return [MarketingStudio.Layer(image: img, frame: NSRect(x: frame.minX + r.midX - 28, y: frame.minY + r.maxY + 10, width: size.width, height: size.height),
                                      radius: 12, dark: dark, shadow: .panel)]
    }
}
#endif
