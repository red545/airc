// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// agent-panel (part "agents"): the Airc Agent panel (⌥⌘A) asking before it pays: the task, its steps and the approval
/// card on a synthetic Corner Shop checkout. The model is the scripted fake from AgentPanelCheck.swift on loopback, with
/// a made-up key in memory; nothing reaches a real provider.
extension SnapshotRunner {
    func mkAgentPanelShot(_ d: MarketingDemo) {
        let fake = FakeModelServer()
        var server: LocalPageServer?
        step { [self] done in
            let s = LocalPageServer(responses: [:])
            s?.requestHandler = { r in
                if r.method == "POST", r.path == "/v1/messages" { return fake.answer(r) }
                return r.path == "/checkout.html" ? LocalPageServer.Page(body: AgentPanelCheck.shop) : nil
            }
            server = s
            s?.start { [self] port in
                guard let port else { note("marketing: MISSING agent-panel: no fixture server"); return done() }
                let loop = "http://127.0.0.1:\(port)"
                var page = "\(loop)/checkout.html"
                if d.serverUp {
                    MarketingServer.extraPages["/agents/checkout.html"] = AgentPanelCheck.shop
                    page = "http://cornershop.aircbrowser.com/agents/checkout.html"
                }
                AgentCenter.shared.app = app
                AgentModelSettings.shared.setTestKey("airc-marketing-made-up-key", provider: .anthropic, base: loop)
                fake.begin("shot", [.tool("navigate", ["url": page]), .tool("find_element", ["text": "Pay"]),
                                    .tool("left_click", ["coordinate": [100, 180]]), .text("Ordered.")])
                AgentPanelController.show(c)
                let p = c.store.profile(ofSpace: c.currentSpaceID)
                AgentRunCenter.shared.ask("Reorder my usual coffee beans from Corner Shop", profileID: p.id, profileName: p.name)
                waitUntil({ AgentRunCenter.shared.approval != nil }, timeout: 20) { done() }
            }
        }
        wait(0.6)
        step { [self] done in
            guard AgentRunCenter.shared.approval != nil, let panel = AgentPanelController.panel(of: c)?.panel, let content = panel.contentView,
                  let pic = MarketingAgentsState.render(content) else {
                note("marketing: MISSING agent-panel: no approval card")
                return done()
            }
            // The panel's material is a window-server blur, which no render draws: its colour goes under the picture.
            let card = NSImage(size: content.bounds.size)
            card.lockFocus()
            (mkIsDark() ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.965, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: content.bounds.size), xRadius: 12, yRadius: 12).fill()
            pic.draw(in: NSRect(origin: .zero, size: content.bounds.size))
            card.unlockFocus()
            let inWindow = c.window.convertFromScreen(panel.frame)
            mkWindowImage { img in
                guard let img else { self.note("marketing: MISSING agent-panel: no capture"); return done() }
                let size = self.c.root.bounds.size
                let (canvas, origin) = MarketingStudio.canvas(around: size)
                let frame = NSRect(origin: origin, size: size)
                let window = MarketingStudio.Layer(image: img, frame: frame, dark: self.mkIsDark(), lights: self.mkLights(self.c.window))
                let over = MarketingStudio.Layer(image: card, frame: inWindow.offsetBy(dx: frame.minX, dy: frame.minY), radius: 12, shadow: .panel)
                self.mkWrite("agent-panel", canvas: canvas, dark: false, [window, over])
                done()
            }
        }
        run { [self] in
            AgentRunCenter.shared.answerApproval(allow: false)
            AgentRunCenter.shared.newConversation()
            AgentPanelController.panel(of: c)?.close()
            AgentModelSettings.shared.setTestKey(nil, provider: .anthropic, base: nil)
            MarketingServer.extraPages["/agents/checkout.html"] = nil
            server?.stop()
        }
        wait(0.4)
    }
}
#endif
