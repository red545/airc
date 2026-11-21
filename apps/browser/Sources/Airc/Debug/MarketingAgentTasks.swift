// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import SwiftUI

/// agent-tasks-ask, agent-task-view, agent-task-approval (part "agents", each also "-dark"; asidepass): the Command
/// Bar's Ask mode with Recent tasks, a task working in its task view with the floating live page, and an approval in the
/// task view. Synthetic sites; the scripted fake model from AgentPanelCheck.swift on loopback with a made-up key.
extension SnapshotRunner {
    static let parksPage = """
    <title>Brightport Parks</title><body style="margin:0;font:15px -apple-system,sans-serif;color:#1d3b2a;background:#eef6ee">
    <div style="height:210px;background:linear-gradient(160deg,#3f8f5a,#9ccf7a 60%,#d9efb8);display:flex;align-items:flex-end;padding:22px">
    <h1 style="color:#fff;margin:0;font-size:34px;text-shadow:0 1px 8px #0004">Brightport Parks</h1></div>
    <div style="padding:22px 26px"><h2 style="margin:0 0 8px">Brightport Commons</h2><p>412 hectares of meadow, a lake and two playgrounds.</p>
    <h2 style="margin:18px 0 8px">Harbour Green</h2><p>Gardens on the old quay.</p></div></body>
    """
    static let audioPage = """
    <title>Sound Lab · Headphones</title><body style="margin:0;font:15px -apple-system,sans-serif;background:#f4f1ec;color:#222">
    <div style="padding:18px 26px;background:#1f1f24;color:#fff;font-weight:600">Sound Lab</div>
    <div style="display:flex;gap:16px;padding:22px 26px">
    <div style="flex:1;background:#fff;border-radius:14px;padding:16px"><div style="height:110px;border-radius:10px;background:linear-gradient(135deg,#c9b8a6,#7d6a58)"></div><b>Quiet One</b><p>€279 · 30 h</p></div>
    <div style="flex:1;background:#fff;border-radius:14px;padding:16px"><div style="height:110px;border-radius:10px;background:linear-gradient(135deg,#9fb3c8,#43566b)"></div><b>Hush Pro</b><p>€249 · 24 h</p></div>
    <div style="flex:1;background:#fff;border-radius:14px;padding:16px"><div style="height:110px;border-radius:10px;background:linear-gradient(135deg,#e5c7c7,#a05b5b)"></div><b>Calm 2</b><p>€199 · 40 h</p></div>
    </div></body>
    """

    func mkAgentTasksShots(_ d: MarketingDemo) {
        let fake = FakeModelServer()
        var server: LocalPageServer?
        var site = ""
        var model = ""
        var appearanceBefore: Appearance?
        let orders = "<title>Corner Shop · Orders</title><body style=\"font:16px -apple-system,sans-serif;margin:0;background:#fffaf2\"><div style=\"padding:18px 26px;background:#f2994a;color:#fff;font-weight:700;font-size:20px\">Corner Shop</div><div style=\"padding:22px 26px\"><h2>Your orders</h2><p>Sourdough loaf × 1 · Oat milk × 2 · Apples × 6</p><button style=\"font-size:16px;padding:8px 16px;border-radius:8px;border:0;background:#2f855a;color:#fff\">Reorder</button></div></body>"
        step { [self] done in
            let s = LocalPageServer(responses: [:])
            s?.requestHandler = { r in
                if r.method == "POST", r.path == "/v1/messages" { return fake.answer(r) }
                switch r.path {
                case "/parks.html": return LocalPageServer.Page(body: Self.parksPage)
                case "/audio.html": return LocalPageServer.Page(body: Self.audioPage)
                case "/orders.html": return LocalPageServer.Page(body: orders)
                case "/checkout.html": return LocalPageServer.Page(body: AgentPanelCheck.shop)
                default: return nil
                }
            }
            server = s
            s?.start { [self] port in
                guard let port else { note("marketing: MISSING agent-tasks: no fixture server"); return done() }
                let loop = "http://127.0.0.1:\(port)"
                site = loop
                model = loop
                if d.serverUp {
                    MarketingServer.extraPages["/agents/parks.html"] = Self.parksPage
                    MarketingServer.extraPages["/agents/audio.html"] = Self.audioPage
                    MarketingServer.extraPages["/agents/orders.html"] = orders
                    MarketingServer.extraPages["/agents/checkout.html"] = AgentPanelCheck.shop
                    site = "http://cornershop.aircbrowser.com/agents"
                }
                AgentCenter.shared.app = app
                AgentUI.forcedForTesting = true
                let none = FileManager.default.temporaryDirectory.appendingPathComponent("airc-shotcli2-\(getpid())", isDirectory: true)
                try? FileManager.default.createDirectory(at: none, withIntermediateDirectories: true)
                AgentCLIDetector.shared.setDirForTesting(none.path)
                AgentModelSettings.shared.update { $0.backend = .apiKey; $0.provider = .anthropic; $0.anthropicModel = "claude-opus-5-5" }
                AgentWatchView.ignoresOcclusion = true
                AgentModelSettings.shared.setTestKey("airc-marketing-made-up-key", provider: .anthropic, base: loop)
                UserDefaults.standard.set(true, forKey: SidebarAgentsView.expandedKey)
                c.sidebar.agents.model.expanded = true
                done()
            }
        }
        // Two finished tasks first (one seen, one not), so the cards and the sidebar have a history.
        func task(_ name: String, _ prompt: String, _ turns: [FakeModelServer.Turn], seen: Bool) {
            step { [self] done in
                AgentRunCenter.shared.newConversation()
                fake.begin(name, turns)
                CommandBarView.startAgentTask(prompt, attached: [], in: c)
                waitUntil({ !AgentRunCenter.shared.state.isActive && AgentRunCenter.shared.steps.contains { $0.kind == .final } }, timeout: 30) {
                    if !seen, let id = AgentTaskRecorder.shared.currentID { AgentTaskRecorder.shared.markUnreadForTesting(id) }
                    done()
                }
            }
            wait(0.6)
        }
        task("t1", "Find the largest park in Brightport", [.tool("navigate", ["url": "\(site)/parks.html"]), .tool("read_page", ["mode": "text"]),
            .text("The largest park in Brightport is **Brightport Commons**: 412 hectares of meadow, with a lake and two playgrounds.")], seen: true)
        task("t2", "Compare noise-cancelling headphones under €300", [.tool("navigate", ["url": "\(site)/audio.html"]), .tool("read_page", ["mode": "text"]),
            .tool("find_element", ["text": "battery"]),
            .text("**Calm 2** (€199) lasts longest at 40 hours; **Quiet One** (€279) has the best noise cancelling; Hush Pro sits between them.")], seen: false)
        for dark in [false, true] {
            let sfx = dark ? "-dark" : ""
            run { [self] in
                if dark { appearanceBefore = c.store.space(c.currentSpaceID)?.theme.appearance }
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                if dark { try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = .dark } }
                c.reloadAll(animated: false)
            }
            wait(0.8)
            // A task working now, in its task view: steps, the live page beside them, the composer.
            step { [self] done in
                AgentRunCenter.shared.stop()
                AgentRunCenter.shared.newConversation()
                fake.begin("t3\(sfx)", [.tool("navigate", ["url": "\(site)/orders.html"]), .tool("read_page", ["mode": "text"]),
                                         .tool("find_element", ["text": "Reorder"]), .toolThenHold("wait", ["duration": 25], hold: 0)])
                CommandBarView.startAgentTask("Reorder last week's groceries from Corner Shop", attached: [], in: c)
                waitUntil({ AgentRunCenter.shared.steps.filter { $0.kind == .action }.count >= 4 }, timeout: 25) { done() }
            }
            wait(2.2)
            mkWindowShot("agent-task-view" + sfx, dark: dark)
            // Ask mode over it: the chips and Recent tasks (the working one live).
            step { [self] done in
                c.openCommandBar(mode: .newTab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                    c.commandBar?.type("Book a table for two at a quiet place near Brightport Commons")
                    c.commandBar?.setAskMode(true)
                    done()
                }
            }
            wait(1.2)
            mkWindowShot("agent-tasks-ask" + sfx, dark: dark)
            run { [self] in c.closeCommandBar() }
            // An approval in the task view.
            step { [self] done in
                AgentRunCenter.shared.stop()
                AgentRunCenter.shared.newConversation()
                fake.begin("t4\(sfx)", [.tool("navigate", ["url": "\(site)/checkout.html"]), .tool("find_element", ["text": "Pay"]),
                                         .tool("left_click", ["coordinate": [100, 180]]), .text("Ordered.")])
                CommandBarView.startAgentTask("Check out my Corner Shop cart", attached: [], in: c)
                waitUntil({ AgentRunCenter.shared.approval != nil }, timeout: 25) { done() }
            }
            wait(1.2)
            mkWindowShot("agent-task-approval" + sfx, dark: dark)
            run { [self] in
                AgentRunCenter.shared.answerApproval(allow: false)
                AgentRunCenter.shared.newConversation()
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
            for p in ["parks", "audio", "orders", "checkout"] { MarketingServer.extraPages["/agents/\(p).html"] = nil }
            server?.stop()
        }
        wait(0.4)
    }
}
#endif
