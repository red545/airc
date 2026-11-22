// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentfix, part of `--script agentpane2` (`AIRC_AGENTPANE2_ONLY=agentfix`), review21's "needs you" routing: a task
/// started from ⌘T → Ask (CommandBarView.startAgentTask) or from a task view's reply (AgentTaskViewModel.ask) in window
/// B, on a Space of another profile, after a pane task in window A: its approval must land in B, on B's Space and
/// profile, and window A must stay as it was.
extension AgentPane2Check {
    /// The other profile's Space and a second window on it.
    func otherProfileWindow(_ done: @escaping (WindowController?, String) -> Void) {
        let home = c.currentSpaceID
        do {
            let p = try c.profiles.createProfile(name: "Agentfix Other", emoji: "", color: nil)
            let s = try c.store.createSpace(name: "Other profile", icon: nil, theme: c.store.selectedSpace.theme, profileID: p.id, after: home)
            app.profiles.whenLoaded(p.id, { [self] _ in
                let b = app.openNewWindow(from: c, spaceID: s.id, commandBar: false)
                after(1.0) { done(b, s.id) }
            }, failed: { [self] in check(false, "agentfix: the other profile loads"); done(nil, s.id) })
        } catch {
            check(false, "agentfix: another profile and its Space (\(error))")
            done(nil, "")
        }
    }

    /// The approval's landing must be in `b` on `space`, never in `a`.
    func landedInOwnWindow(_ label: String, a: WindowController, aSpace: String, b: WindowController, space: String, profile: String,
                           _ done: @escaping () -> Void) {
        wait({ AgentAttention.lastLanding?.item.kind == .approval && AgentAttention.lastLanding?.window != nil }, 4) { [self] in
            after(0.6) { [self] in
                let w = AgentAttention.lastLanding?.window
                check(w === b, "\(label): lands in the task's own window (B), not the window of an earlier pane task (A) (landed in \(w === a ? "A" : w === b ? "B" : "none"))")
                check(b.currentSpaceID == space, "\(label): … on the task's Space")
                let landedProfile = w.map { $0.store.profile(ofSpace: $0.currentSpaceID).id }
                check(landedProfile == profile, "\(label): … in the task's profile (never another profile's window)")
                check(a.currentSpaceID == aSpace, "\(label): … window A stays on its own Space")
                check(AgentPaneController.pane(of: a)?.model.approvalFocused != true, "\(label): … and A's pane doesn't take the approval")
                done()
            }
        }
    }

    func caseRouteNeedsYou(_ done: @escaping () -> Void) {
        traceAttention()
        AgentAttention.resetForTesting()
        let a = c
        let aSpace = a.currentSpaceID
        func shopTurns(_ end: String) -> [FakeModelServer.Turn] {
            [.tool("navigate", ["url": "\(k.base)/shop.html"]), .tool("left_click", ["coordinate": [100, 180]]), .text(end)]
        }
        otherProfileWindow { [self] b, space in
            guard let b else { return done() }
            let profile = b.store.profile(ofSpace: space).id
            check(b.currentSpaceID == space && profile != a.store.profile(ofSpace: aSpace).id, "agentfix route: window B on a Space of another profile")
            func finish() {
                run.stop()
                k.untilIdle(8) { [self] in
                    b.window.close()
                    a.window.makeKeyAndOrderFront(nil)
                    after(0.5) { done() }
                }
            }
            // A pane task in window A first (it records A as the task's window). Window A is made key first and the
            // task starts in A's own pane: with open -g (posted) A doesn't become key by itself, and k.c is still B.
            keyA(a, "agentfix route") { [self] in
            k.start("route-a", [.text("Hello from A.")], task: "Say hello", in: a)
            k.untilIdle(15) { [self] in
                check(AgentAttention.taskWindow === a, "agentfix route: the pane task in A records A")
                // ⌘T → Ask in window B.
                b.window.makeKeyAndOrderFront(nil)
                k.fake.begin("route-b", shopTurns("Paid in B."))
                CommandBarView.startAgentTask("Pay at the fixture shop", attached: [], in: b)
                wait({ self.run.approval != nil }, 20) { [self] in
                    guard run.approval != nil else { check(false, "agentfix route [⌘T Ask]: the agent asks before paying"); return finish() }
                    check(run.profileID == profile, "agentfix route [⌘T Ask]: the task runs in B's profile")
                    // The person is in window A when the click comes.
                    a.window.makeKeyAndOrderFront(nil)
                    after(0.5) { [self] in
                        enter("agentButton", in: a) { [self] how in
                            landedInOwnWindow("agentfix route [⌘T Ask, ✦ in A] [\(how)]", a: a, aSpace: aSpace, b: b, space: space, profile: profile) { [self] in
                                run.answerApproval(allow: false)
                                k.untilIdle(8) { [self] in taskViewReply(a: a, aSpace: aSpace, b: b, space: space, profile: profile, turns: shopTurns("Paid again."), finish) }
                            }
                        }
                    }
                }
            }
            }
        }
    }

    /// Window A key before a pane task starts in it: ordered front, and the app activated only if A doesn't become key
    /// (a background, posted run), then asserted.
    func keyA(_ a: WindowController, _ label: String, _ then: @escaping () -> Void) {
        a.window.makeKeyAndOrderFront(nil)
        after(0.3) { [self] in
            if !a.window.isKeyWindow { NSApp.activate(ignoringOtherApps: true); a.window.makeKeyAndOrderFront(nil) }
            wait({ a.window.isKeyWindow }, 6) { [self] in
                check(a.window.isKeyWindow, "\(label): window A is key before its pane task (active \(NSApp.isActive))")
                then()
            }
        }
    }

    /// The reply in B's task view (AgentTaskViewModel.ask), after another pane task in A.
    private func taskViewReply(a: WindowController, aSpace: String, b: WindowController, space: String, profile: String,
                               turns: [FakeModelServer.Turn], _ finish: @escaping () -> Void) {
        keyA(a, "agentfix route [task view]") { [self] in
        k.start("route-a2", [.text("Hello again from A.")], task: "Say hello again", in: a)
        k.untilIdle(15) { [self] in
            let tab = b.store.state.tabs.values.first { $0.spaceID == space && AgentTasksURL.isPage($0.url) }
            guard let vm = AgentTasksPage.existing(tab?.id)?.task, vm.controller === b else {
                check(false, "agentfix route [task view]: B's task view is open on the ⌘T task (tab \(tab?.id ?? "none"))")
                return finish()
            }
            b.window.makeKeyAndOrderFront(nil)
            k.fake.begin("route-b2", turns)
            vm.text = "Pay once more"
            vm.send()
            wait({ self.run.approval != nil }, 20) { [self] in
                guard run.approval != nil else { check(false, "agentfix route [task view]: the agent asks before paying"); return finish() }
                a.window.makeKeyAndOrderFront(nil)
                after(0.5) { [self] in
                    enter("agentButton", in: a) { [self] how in
                        landedInOwnWindow("agentfix route [task view reply, ✦ in A] [\(how)]", a: a, aSpace: aSpace, b: b, space: space, profile: profile) {
                            self.run.answerApproval(allow: false)
                            finish()
                        }
                    }
                }
            }
        }
        }
    }
}
#endif
