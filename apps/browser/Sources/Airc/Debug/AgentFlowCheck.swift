// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentflow (agentuxreview #1, #2; docs/design/agent-ux.md §3, §5): "send at the next step" and follow-ups after Stop.
/// - agentpane (`AgentPaneCheck.caseFlow`, the FakeModelServer): real ↩ while it works queues a pending bubble, the field
///   empties, and the next step's request carries it once; a note typed during the last answer makes one more turn; ✕
///   and ✎ take it back; Stop keeps it pending, and the reply after Stop sends it as its own line before the reply (never
///   glued on) in the same tab, with no new Today row; ⌘↩ stops and sends at once, in the same tab.
/// - agentpane2 (`AgentPane2Check.caseFlowCLI`, the fake Claude Code and Codex): the note goes with the CLI's next tool
///   answer; typed during its last answer, it is the CLI's next turn in the same session.
/// Real driver keys and clicks in a dedicated session; else posted, and said so.
extension AgentPaneCheck {
    static let flowNote = "Only gooseneck"

    func caseFlow(_ done: @escaping () -> Void) {
        flowNext { [self] in flowLast { [self] in flowRemove { [self] in flowStopReply { [self] in flowNow(done) } } } }
    }

    /// Return as the person presses it: a real key into the focused field, else the model's send.
    func flowReturn(_ combo: String = "return", _ done: @escaping (String) -> Void) {
        guard real else {
            if combo == "return" { model?.send() } else { model?.sendNow() }
            return done("posted")
        }
        key(combo) { [self] ok in
            if !ok {
                note("FAIL-ENV \(label) \(engine): the driver refused \(combo); posted")
                if combo == "return" { model?.send() } else { model?.sendNow() }
            }
            after(0.3) { done(ok ? "real" : "posted") }
        }
    }

    var spaceTabs: Int { c.store.state.tabs.values.filter { $0.spaceID == c.currentSpaceID }.count }

    /// No user line glues a note onto other text.
    func notGlued(_ note: String) -> Bool {
        run.steps.filter { $0.kind == .user }.allSatisfy { $0.text == note || !$0.text.contains(note) }
    }

    // ↩ while a tool runs: pending, then in the next request once.
    func flowNext(_ done: @escaping () -> Void) {
        let note = Self.flowNote
        start("flownext", [.tool("navigate", ["url": "\(base)/article.html"]), .tool("wait", ["duration": 9]), .text("Noted: gooseneck kettles only.")],
              task: "Find a kettle for me")
        runner.waitUntil({ self.events.contains("tool wait") }, timeout: 20) { [self] in
            type(note) { [self] typed in
                flowReturn { [self] how in
                    check(run.pendingNotes.map(\.text) == [note] && (model?.text ?? "x").isEmpty,
                          "agentflow: ↩ while it works queues the message, the field empties [\(how) key, \(typed) typing] (pending \(run.pendingNotes.map(\.text)), field “\(model?.text ?? "")”)")
                    check(point("agentpane.pending") != nil, "agentflow: … as a pending bubble in the pane")
                    check(run.state.isActive && !run.steps.contains { $0.text.contains(note) }, "agentflow: … not delivered yet, the task goes on")
                    check(fake.bodies("flownext").allSatisfy { !$0.contains(note) }, "agentflow: … the model hasn't had it yet")
                    shot("agentflow-pending")
                    untilIdle(30) { [self] in
                        let bodies = fake.bodies("flownext")
                        check(bodies.count == 3 && (bodies.last ?? "").components(separatedBy: note).count == 2,
                              "agentflow: the next step's request carries it, once (\(bodies.count) requests, \(max(0, (bodies.last ?? "").components(separatedBy: note).count - 1))×)")
                        check(bodies.dropLast().allSatisfy { !$0.contains(note) }, "agentflow: … no earlier request does")
                        check(run.steps.filter { $0.kind == .user && $0.midRun }.map(\.text) == [note] && run.pendingNotes.isEmpty,
                              "agentflow: … it's the person's own line in the transcript now, nothing pending")
                        check(notGlued(note), "agentflow: … never glued onto another message")
                        check(finalText == "Noted: gooseneck kettles only.", "agentflow: … and the task goes on to its end (“\(finalText)”)")
                        done()
                    }
                }
            }
        }
    }

    // ↩ during the final answer: one more turn with it.
    func flowLast(_ done: @escaping () -> Void) {
        let note = "Also cheap"
        let long = Array(repeating: "The Pour kettle is a fine choice and pours well.", count: 9).joined(separator: " ")
        start("flowlast", [.tool("navigate", ["url": "\(base)/article.html"]), .slowText(long, every: 0.15), .text("With that in mind: the Rapid.")],
              task: "Pick a kettle")
        runner.waitUntil({ !self.run.partial.isEmpty }, timeout: 20) { [self] in
            type(note) { [self] typed in
                flowReturn { [self] how in
                    check(run.pendingNotes.map(\.text) == [note], "agentflow: ↩ while it writes its answer queues the message [\(how) key, \(typed) typing]")
                    untilIdle(40) { [self] in
                        let bodies = fake.bodies("flowlast")
                        check(bodies.count == 3 && (bodies.last ?? "").contains(note), "agentflow: … the answer's end sends it as one more turn (\(bodies.count) requests)")
                        check(run.steps.filter { $0.kind == .final }.count == 2 && finalText == "With that in mind: the Rapid.",
                              "agentflow: … which answers it (“\(finalText)”)")
                        check(notGlued(note) && run.pendingNotes.isEmpty, "agentflow: … its own line, nothing pending")
                        done()
                    }
                }
            }
        }
    }

    // ✕ removes a pending message; ✎ puts it back into the field.
    func flowRemove(_ done: @escaping () -> Void) {
        start("flowrm", [.tool("navigate", ["url": "\(base)/article.html"]), .tool("wait", ["duration": 14]), .text("Done without notes.")], task: "Find a kettle")
        runner.waitUntil({ self.events.contains("tool wait") }, timeout: 20) { [self] in
            type("Skip") { [self] _ in
                flowReturn { [self] how in
                    check(run.pendingNotes.count == 1, "agentflow: a second pending message [\(how) key]")
                    press("agentpane.pending.remove", "✕ on the pending message", fallback: { if let n = self.run.pendingNotes.first { self.model?.removeNote(n.id) } }) { [self] how in
                        after(0.3) { [self] in
                            check(run.pendingNotes.isEmpty && point("agentpane.pending") == nil, "agentflow: ✕ removes it [\(how) click]")
                            type("Later") { [self] _ in
                                flowReturn { [self] _ in
                                    press("agentpane.pending.edit", "✎ on the pending message", fallback: { if let n = self.run.pendingNotes.first { self.model?.editNote(n.id) } }) { [self] how in
                                        after(0.3) { [self] in
                                            check(run.pendingNotes.isEmpty && model?.text == "Later", "agentflow: ✎ takes it back into the field to edit [\(how) click] (“\(model?.text ?? "")”)")
                                            model?.text = ""
                                            untilIdle(30) { [self] in
                                                check(fake.bodies("flowrm").allSatisfy { !$0.contains("Skip") && !$0.contains("Later") },
                                                      "agentflow: … neither reaches the model (\(fake.bodies("flowrm").count) requests)")
                                                check(finalText == "Done without notes.", "agentflow: … and the task ends as it would have")
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

    // The review's repro: a message while it works, Stop, then a reply: two lines, one task, the same tab.
    func flowStopReply(_ done: @escaping () -> Void) {
        let note = "Gooseneck"
        start("flowstop", [.tool("navigate", ["url": "\(base)/article.html"]), .tool("wait", ["duration": 30]), .text("Never reached.")], task: "Find me a kettle")
        runner.waitUntil({ self.events.contains("tool wait") && self.c.shownTabID.map { self.c.store.tab($0)?.url.hasSuffix("/article.html") == true } == true },
                         timeout: 20) { [self] in
            let tab = c.shownTabID
            let tabs = spaceTabs
            type(note) { [self] _ in
                flowReturn { [self] how in
                    check(run.pendingNotes.count == 1, "agentflow: (stop) the message is pending [\(how) key]")
                    press("agentpane.stop", "Stop", fallback: { self.run.stop() }) { [self] how in
                        untilIdle(6) { [self] in
                            if case .stopped = run.state { check(true, "agentflow: (stop) Stop ends the task [\(how) click]") } else { check(false, "agentflow: (stop) Stop ends the task (\(run.state))") }
                            check(run.pendingNotes.map(\.text) == [note] && point("agentpane.pending") != nil,
                                  "agentflow: (stop) the message stays pending, to go with the next reply (\(run.pendingNotes.map(\.text)))")
                            check((model?.text ?? "x").isEmpty, "agentflow: (stop) … and isn't left in the field to glue onto the reply")
                            let kept = Self.modelTurns(items: run.conversationItemsForTesting)
                            fake.begin("flowstop2", [.text("Going on with gooseneck kettles.")], offset: kept)
                            after(0.5) { [self] in
                                type("Go on") { [self] typed in
                                    flowReturn { [self] how in
                                        runner.waitUntil({ self.fake.requests(for: "flowstop2") > 0 && !self.run.state.isActive }, timeout: 25) { [self] in
                                            let body = fake.bodies("flowstop2").first ?? ""
                                            check(body.contains(note) && body.contains("Go on") && !body.contains(note + "Go on"),
                                                  "agentflow: (stop) the reply sends the pending message and the reply, not glued [\(how) key, \(typed) typing]")
                                            let users = run.steps.filter { $0.kind == .user }.suffix(2).map { "\($0.midRun ? "note" : "prompt"):\($0.text)" }
                                            check(users == ["note:\(note)", "prompt:Go on"] && notGlued(note), "agentflow: (stop) … two lines in the transcript (\(users))")
                                            check(finalText == "Going on with gooseneck kettles.", "agentflow: (stop) … and the task goes on (“\(finalText)”)")
                                            check(c.shownTabID == tab && c.store.tab(c.shownTabID)?.url.hasSuffix("/article.html") == true,
                                                  "agentflow: (stop) the follow-up goes on in the task's tab (\(tab ?? "none") → \(c.shownTabID ?? "none"))")
                                            check(spaceTabs == tabs, "agentflow: (stop) … no new Today row (\(tabs) → \(spaceTabs) tabs)")
                                            shot("agentflow-stopreply")
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

    // ⌘↩: stop now and send, in the same tab.
    func flowNow(_ done: @escaping () -> Void) {
        start("flownow", [.tool("navigate", ["url": "\(base)/article.html"]), .tool("wait", ["duration": 30]), .text("Never reached.")], task: "Find a kettle quickly")
        runner.waitUntil({ self.events.contains("tool wait") && self.c.shownTabID.map { self.c.store.tab($0)?.url.hasSuffix("/article.html") == true } == true },
                         timeout: 20) { [self] in
            let tab = c.shownTabID
            let tabs = spaceTabs
            type("Now please") { [self] typed in
                fake.begin("flownow2", [.text("Right away.")], offset: Self.modelTurns(items: run.conversationItemsForTesting))
                let t0 = Date()
                flowReturn("cmd+return") { [self] how in
                    runner.waitUntil({ self.fake.requests(for: "flownow2") > 0 && !self.run.state.isActive }, timeout: 20) { [self] in
                        let ms = Int(Date().timeIntervalSince(t0) * 1000)
                        check(run.steps.contains { $0.kind == .info && $0.text.contains("stopped") } && finalText == "Right away.",
                              "agentflow: ⌘↩ stops the step and sends at once [\(how) key, \(typed) typing] (\(ms) ms to the answer)")
                        check(run.steps.last { $0.kind == .user }?.text == "Now please" && (fake.bodies("flownow2").first ?? "").components(separatedBy: "Now please").count == 2,
                              "agentflow: … as its own message, once")
                        check(!finalText.contains("Never reached"), "agentflow: … the stopped step doesn't go on")
                        check(c.shownTabID == tab && spaceTabs == tabs, "agentflow: … in the same tab, no new Today row (\(tabs) → \(spaceTabs))")
                        done()
                    }
                }
            }
        }
    }
}

extension AgentPane2Check {
    /// The fake Claude Code / Codex: a note while its tool runs goes with that tool's answer; one typed during its last
    /// answer is its next turn.
    func caseFlowCLI(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let name = "flowcli-\(kind.binary)"
        let note = "Only the intro"
        run.newConversation()
        k.setKeys(anthropic: false)
        installFakes(case: name, loggedIn: true, turns: [[["tool": "navigate", "args": ["url": "\(k.base)/article.html"]],
                                                         ["tool": "wait", "args": ["duration": 8]],
                                                         ["say": "Read it, with your note."]]])
        AgentCLIDetector.shared.setDirForTesting(pathDir.path)
        AgentModelSettings.shared.setBackendForTesting(kind == .claudeCode ? .claudeCode : .codex)
        AgentPaneProvider.refresh()
        wait({ self.row(kind)?.ready == true }, 15) { [self] in
            let p = AgentPaneController.show(c)
            p.model.cancelSetup()
            p.model.newTask()
            p.model.text = "Read the article"
            p.model.send()
            wait({ self.k.events.contains("cli call wait") || self.fakeEvents("tool").contains { $0["case"] as? String == name && $0["name"] as? String == "navigate" } }, 25) { [self] in
                after(0.5) { [self] in
                    k.type(note) { [self] typed in
                        k.flowReturn { [self] how in
                            check(run.pendingNotes.map(\.text) == [note], "agentflow [\(kind.name)]: ↩ while it works queues the message [\(how) key, \(typed) typing]")
                            k.untilIdle(40) { [self] in
                                let tools = fakeEvents("tool").filter { $0["case"] as? String == name }
                                let carrying = tools.filter { ($0["result"] as? String ?? "").contains(note) }
                                check(carrying.count == 1, "agentflow [\(kind.name)]: the next tool answer carries it, once (\(carrying.map { $0["name"] as? String ?? "?" }) of \(tools.count) tools)")
                                check(run.state == .done && run.steps.filter { $0.kind == .user && $0.midRun }.map(\.text) == [note] && run.pendingNotes.isEmpty,
                                      "agentflow [\(kind.name)]: … its own line, nothing pending, the task done (\(run.state))")
                                caseFlowCLILast(kind, done)
                            }
                        }
                    }
                }
            }
        }
    }

    func caseFlowCLILast(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let name = "flowcli2-\(kind.binary)"
        let note = "And the price"
        run.newConversation()
        let long = Array(repeating: "The article is about kettles and pours well.", count: 8).joined(separator: " ")
        installFakes(case: name, loggedIn: true, turns: [[["say": long, "every": 0.2]], [["say": "The price is in the second part."]]])
        let p = AgentPaneController.show(c)
        p.model.newTask()
        p.model.text = "Summarize the article"
        p.model.send()
        wait({ !self.run.partial.isEmpty }, 25) { [self] in
            k.type(note) { [self] typed in
                k.flowReturn { [self] how in
                    check(run.pendingNotes.map(\.text) == [note], "agentflow [\(kind.name)]: ↩ during its answer queues the message [\(how) key, \(typed) typing]")
                    k.untilIdle(40) { [self] in
                        let turns = fakeEvents("turn").filter { $0["case"] as? String == name }
                        check(turns.count == 2 && (turns.last?["text"] as? String ?? "").contains(note),
                              "agentflow [\(kind.name)]: … it's the CLI's next turn, in the same session (\(turns.count) turns)")
                        check(run.state == .done && k.finalText == "The price is in the second part.", "agentflow [\(kind.name)]: … which answers it (“\(k.finalText)”)")
                        AgentModelSettings.shared.update { $0.backend = .apiKey }
                        done()
                    }
                }
            }
        }
    }
}

extension AgentTasksCheck {
    /// The task view's composer: ↩ while it works queues the message there too (listed above the field), and the next
    /// step's request carries it.
    func caseFlowTaskView(_ done: @escaping () -> Void) {
        // The reply before this one brought the task's page back into the main view: its task view, again.
        if let id = recorder.currentID { AgentTasksPage.openTask(id, in: c, view: true) }
        wait({ self.taskPage?.task.isCurrent == true }, 4) { [self] in flowTaskView(done) }
    }

    private func flowTaskView(_ done: @escaping () -> Void) {
        guard let page = taskPage, page.task.isCurrent else {
            check(false, "agentflow: the task view of a task of this launch is shown (shown \(c.store.tab(c.shownTabID)?.url ?? "none"))")
            return done()
        }
        let note = "Only the north gate"
        k.fake.begin("flowtv", [.tool("navigate", ["url": "\(k.base)/park.html"]), .tool("wait", ["duration": 16]), .text("The north gate opens at 7.")],
                     offset: AgentPaneCheck.modelTurns(items: run.conversationItemsForTesting))
        page.task.text = "When do the gates open?"
        page.task.send()
        // The second request answers with the wait (16 s): the message goes in while it runs.
        wait({ self.k.fake.requests(for: "flowtv") >= 2 && self.run.state.isActive }, 20) { [self] in
            // The reply brought the task's page into the main view (runResumed): back to its task view to type there.
            if let id = recorder.currentID { AgentTasksPage.openTask(id, in: c, view: true) }
            wait({ self.taskPage?.task.isCurrent == true && self.taskHost != nil }, 4) { [self] in
            guard let page = taskPage else { check(false, "agentflow: the task view is shown again while it works"); return done() }
            let send: (@escaping (String) -> Void) -> Void = { [self] k2 in
                guard real, let h = taskHost else { page.task.text = note; page.task.send(); return k2("posted") }
                k.press("agenttask.field", "the task view's field", in: h, fallback: {}) { [self] _ in
                    typeInBar(note) { [self] how in barKey("return") { _ in k2(how) } }
                }
            }
            send { [self] how in
                after(0.4) { [self] in
                    check(run.pendingNotes.map(\.text) == [note] && page.task.text.isEmpty && inTask("agenttask.pending"),
                          "agentflow: the task view's ↩ while it works queues the message, listed above the field [\(how)] (\(run.pendingNotes.map(\.text)))")
                    wait({ !self.run.state.isActive }, 30) { [self] in
                        let last = k.fake.bodies("flowtv").last ?? ""
                        check(last.components(separatedBy: note).count == 2 && run.pendingNotes.isEmpty && k.finalText == "The north gate opens at 7.",
                              "agentflow: … the next step's request carries it once, and the task goes on (“\(k.finalText)”)")
                        done()
                    }
                }
            }
            }
        }
    }
}
#endif
