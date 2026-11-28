// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentpanescope (docs/design/agent-ux.md §3): the pane's shown task is per window AND Space, and the pane's field keeps
/// the keyboard when it opens. Opt-in cases of `--script agentparallel` (its FakeModelServer scripts per task and tally
/// pages), only when named: `AIRC_AGENTPARALLEL_ONLY=spaces,panefocus`.
/// - spaces: two Spaces of one window, a task in each: switching Spaces (real ⌥⌘→ / ⌥⌘←) shows that Space's last task
///   in the pane (or the empty state in a Space that has none) and coming back restores it; open/closed stays per Space;
///   ✎ New, a row pick, ⌘T Ask and ⌥↩ act in the Space they're used in; the field's text is kept per Space; a new window
///   starts empty; every task keeps running through the switches and finishes with its own answer and page counts.
/// - panefocus: the pane opens (real ⌥⌘A) and the page takes the keyboard back a moment later (no input from the
///   person): the field gets it back; a page that keeps taking it wins after a few tries (no tug of war); a real click
///   on the page right after the pane opened leaves the keys on the page.
extension AgentParallelCheck {
    /// The window to `id` with the Space shortcut (real keys in a dedicated session), else by call.
    func toSpace(_ w: WindowController, _ id: String, _ combo: String, _ done: @escaping (String) -> Void) {
        spaceLog.append((Date(), "switch \(combo)"))
        let settle = { [self] (how: String) in
            wait({ w.currentSpaceID == id }, 3) { [self] in
                check(w.currentSpaceID == id, "spaces: \(combo) switches the window's Space [\(how)]")
                if w.currentSpaceID != id { w.switchToSpace(id, animated: false) }
                after(0.6) { done(how) }
            }
        }
        guard k.real, w.window.isKeyWindow, NSApp.isActive else { w.switchToSpace(id, animated: true); return settle("posted") }
        k.key(combo) { ok in
            if !ok { w.switchToSpace(id, animated: true) }
            settle(ok ? "real key" : "posted")
        }
    }

    /// ⌥⌘A: real key, else the call.
    func togglePane(_ w: WindowController, _ done: @escaping (String) -> Void) {
        guard k.real, w.window.isKeyWindow, NSApp.isActive else { AgentUI.toggle(w); return after(0.5) { done("posted") } }
        k.key("cmd+opt+a") { [self] ok in
            if !ok { AgentUI.toggle(w) }
            after(0.5) { done(ok ? "real key" : "posted") }
        }
    }

    func caseSpaces(_ done: @escaping () -> Void) {
        events = []
        // Diagnosis (A/B): the idle rest of parked pages off for this case.
        if ProcessInfo.processInfo.environment["AIRC_SPACES_NOREST"] == "1" {
            AgentIdleRest.enabled = false
            note("agentparallel \(engine): spaces: idle rest OFF (AIRC_SPACES_NOREST=1)")
        }
        let a = home!
        let aSpace = a.currentSpaceID
        let profile = a.store.profile(ofSpace: aSpace)
        guard let made = try? a.store.createSpace(name: "Pane other", icon: nil, theme: a.store.selectedSpace.theme, profileID: profile.id, after: aSpace) else {
            check(false, "spaces: a second Space of the window's profile"); return done()
        }
        let pane = AgentPaneController.show(a)
        let bSpace = made.id
        let model = pane.model
        spaceLog = []
        let t0 = Date()
        let mainBefore = main.onEvent
        main.onEvent = { [weak self] e in self?.spaceLog.append((Date(), "main " + e)); mainBefore?(e) }
        var runs: [String: AgentRunCenter] = [:]
        func shown() -> String { runs.first { $0.value === model.run }?.key ?? (model.run.steps.isEmpty ? "empty" : "other") }
        func fake(_ name: String, _ n: Int, holds: Double) { k.fake.begin(tagged: "[[\(name)]]", name, tally(n, "\(name) done.", holds: holds)) }
        a.window.makeKeyAndOrderFront(nil)
        // Space A: task s1, long enough to run through the switches.
        guard let r1 = start("s1", tally(1, "s1 done.", holds: 14), task: "Count on tally page 1", in: a) else {
            check(false, "spaces: task s1 starts in Space A"); return done()
        }
        runs["s1"] = r1
        // Which of s1's clicks counts (diagnosis): its page's counter once it waits (after click 1), and again before click 2.
        wait({ self.events.contains { $0.task == "s1" && $0.event == "tool wait" } }, 10) { [self] in
            after(1.0) { [self] in
                read("window.counts||0", on: page(r1) ?? tabPage(r1)) { [self] n in
                    note("agentparallel \(engine): spaces: s1's page after its first click: \(n) (+\(String(format: "%.2f", Date().timeIntervalSince(t0))) s, parked \(main.entry(for: r1).flatMap { e in e.page.map { e.window?.isParked($0) == true } } ?? false))")
                }
            }
            after(12.0) { [self] in
                read("window.counts||0", on: page(r1) ?? tabPage(r1)) { [self] n in
                    note("agentparallel \(engine): spaces: s1's page before its second click: \(n) (+\(String(format: "%.2f", Date().timeIntervalSince(t0))) s)")
                }
            }
        }
        // The person switches once the task's page is there (asked and switched at once: see the report's Left).
        wait({ r1.state.isActive && model.run === r1 && self.main.entry(for: r1) != nil }, 6) { [self] in
            check(model.run === r1 && pane.isShown, "spaces: Space A's pane shows task s1 (\(shown()))")
            let t1 = main.entry(for: r1).flatMap { a.store.tab($0.tabID)?.spaceID }
            note("agentparallel \(engine): spaces: Spaces \(a.store.orderedSpaces.map { "\($0.id.prefix(6)) “\($0.name)”" }), A \(aSpace.prefix(6)), B \(bSpace.prefix(6)); s1's tab when presented: \(t1.map { String($0.prefix(6)) } ?? "none")")
            toSpace(a, bSpace, "cmd+opt+right") { [self] how in
                check(!pane.isShown && pane.card == nil, "spaces: Space B: the pane is closed there (open/closed per Space) [\(how)]")
                check(model.run !== r1 && model.run.steps.isEmpty && !model.run.isBusy, "spaces: … and holds Space B's own (empty) state, not s1 (\(shown()))")
                check(r1.isBusy, "spaces: s1 keeps running in Space A (\(r1.state))")
                togglePane(a) { [self] how in
                    check(pane.isShown && model.mode == .newTask && model.title == "New task",
                          "spaces: ⌥⌘A in Space B opens the pane on the empty new-task state (\(model.mode), “\(model.title)”) [\(how)]")
                    guard let r2 = start("s2", tally(2, "s2 done.", holds: 10), task: "Count on tally page 2", in: a) else {
                        check(false, "spaces: task s2 starts in Space B"); return done()
                    }
                    runs["s2"] = r2
                    wait({ r2.state.isActive && model.run === r2 }, 6) { [self] in
                        check(model.run === r2, "spaces: Space B's pane shows task s2 (\(shown()))")
                        wait({ self.main.entry(for: r1) != nil && self.main.entry(for: r2) != nil }, 6) { [self] in
                        let t1 = main.entry(for: r1)?.tabID, t2 = main.entry(for: r2)?.tabID
                        let s1 = t1.flatMap { a.store.tab($0)?.spaceID }, s2 = t2.flatMap { a.store.tab($0)?.spaceID }
                        check(s1 == aSpace && s2 == bSpace,
                              "spaces: … each task's page is a tab of its own Space (s1 \(s1 == aSpace ? "A" : s1.map { String($0.prefix(6)) } ?? "no tab"), s2 \(s2 == bSpace ? "B" : s2.map { String($0.prefix(6)) } ?? "no tab"); A \(aSpace.prefix(6)), B \(bSpace.prefix(6)))")
                        toSpace(a, aSpace, "cmd+opt+left") { [self] how in
                            check(pane.isShown && model.run === r1, "spaces: back in Space A: the pane is open on s1 again (\(shown())) [\(how)]")
                            check(r1.isBusy && r2.isBusy, "spaces: … both tasks still run (s1 \(r1.state), s2 \(r2.state))")
                            toSpace(a, bSpace, "cmd+opt+right") { [self] how in
                                check(pane.isShown && model.run === r2, "spaces: back in Space B: s2 again (\(shown())) [\(how)]")
                                newAndDraft(a, pane, aSpace, bSpace, r1, r2, runs: { runs[$0] = $1 }, shown: shown, fake: fake) { [self] in
                                    wait({ runs.count >= 4 && runs.values.allSatisfy { !$0.isBusy } }, 60) { [self] in
                                        for (name, r) in runs.sorted(by: { $0.key < $1.key }) {
                                            let answer = r.steps.last { $0.kind == .final }?.text ?? ""
                                            check(r.state == .done && answer == "\(name) done.", "spaces: \(name) ran through the switches to its own answer (\(r.state), “\(answer)”)")
                                        }
                                        let order = runs.keys.sorted()
                                        var counts: [Int] = []
                                        func next(_ i: Int) {
                                            guard i < order.count else {
                                                // agentparkclick: s1's second click lands while its page is parked after several Space switches
                                                // (it parked at Space B's laid-out size and came back at A's, so the click was refused as a
                                                // stale look). Asserted by default; AIRC_SPACES_STRICT=0 only notes it.
                                                let strict = ProcessInfo.processInfo.environment["AIRC_SPACES_STRICT"] != "0"
                                                let ok = zip(order, counts).allSatisfy { name, n in name == "s1" && !strict ? n >= 1 : n == 2 }
                                                check(ok, "spaces: each page counted its own task's clicks (\(zip(order, counts).map { "\($0) \($1)" })\(strict ? "" : "; s1's second click not asserted (AIRC_SPACES_STRICT=0)"))")
                                                // No click of any task was refused for a page change the person never made (no scroll, no resize).
                                                let refused = runs.sorted(by: { $0.key < $1.key }).flatMap { name, r in
                                                    r.steps.filter { $0.detail?.contains("The page moved since your last look") == true }.map { _ in name }
                                                }
                                                check(refused.isEmpty, "spaces: no agent click was refused as a stale look after the Space switches (\(refused.isEmpty ? "none" : refused.joined(separator: ", ")))")
                                                if !ok || ProcessInfo.processInfo.environment["AIRC_SPACES_DIAG"] == "1" { spaceDiagnostics(t0, runs) }
                                                main.onEvent = mainBefore
                                                return finishSpaces(a, pane, aSpace, bSpace, runs, shown: shown, done)
                                            }
                                            let r = runs[order[i]]!
                                            read("window.counts||0", on: page(r) ?? tabPage(r)) { n in counts.append(n); next(i + 1) }
                                        }
                                        next(0)
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

    /// What happened to each task's page while the Spaces switched (for a red page count).
    func spaceDiagnostics(_ t0: Date, _ runs: [String: AgentRunCenter]) {
        func at(_ d: Date) -> String { String(format: "%.2f", d.timeIntervalSince(t0)) }
        for (d, e) in spaceLog { note("agentparallel \(engine): spaces log +\(at(d)) \(e)") }
        for (name, r) in runs.sorted(by: { $0.key < $1.key }) {
            for (task, e, d) in events where task == name { note("agentparallel \(engine): spaces \(name) +\(at(d)) \(e)") }
            for st in r.steps where st.kind == .action || st.kind == .error || st.kind == .info {
                note("agentparallel \(engine): spaces \(name) step \(st.kind): \(st.text)\(st.detail.map { " (\($0))" } ?? "")")
            }
            note("agentparallel \(engine): spaces \(name) tab \(main.entry(for: r)?.tabID ?? "none")")
        }
    }

    /// ✎ New and the field's text per Space, a row pick, ⌘T Ask in B, ⌥↩ in A, a new window.
    private func newAndDraft(_ a: WindowController, _ pane: AgentPaneController, _ aSpace: String, _ bSpace: String,
                             _ r1: AgentRunCenter, _ r2: AgentRunCenter, runs add: @escaping (String, AgentRunCenter) -> Void,
                             shown: @escaping () -> String, fake: @escaping (String, Int, Double) -> Void, _ done: @escaping () -> Void) {
        let model = pane.model
        // ✎ New in B: the empty state; s2 goes on. A draft typed there stays B's.
        model.newTask()
        check(model.run.steps.isEmpty && r2.isBusy, "spaces: ✎ New in Space B: an empty task, s2 goes on (\(r2.state))")
        model.text = "draft for space B"
        toSpace(a, aSpace, "cmd+opt+left") { [self] how in
            check(model.run === r1 && model.text.isEmpty, "spaces: Space A: s1, with A's own (empty) field (\(shown()), “\(model.text)”) [\(how)]")
            toSpace(a, bSpace, "cmd+opt+right") { [self] how in
                check(model.run.steps.isEmpty && model.text == "draft for space B", "spaces: Space B: the empty task and its draft are back (\(shown()), “\(model.text)”) [\(how)]")
                model.text = ""
                // A task row / Recent-tasks card pick (AgentPaneController.show(_:task:)) shows that task in this Space.
                AgentPaneController.show(a, task: r2)
                check(model.run === r2, "spaces: picking s2 (its row) in Space B shows it (\(shown()))")
                // ⌘T Ask in B: a new task of its own in B's pane.
                fake("s3", 3, 6)
                CommandBarView.startAgentTask("Count on tally page 3 [[s3]]", attached: [], in: a)
                wait({ AgentTaskCenter.shared.runs.contains { $0.steps.first?.text.contains("[[s3]]") == true } }, 4) { [self] in
                    guard let r3 = AgentTaskCenter.shared.runs.first(where: { $0.steps.first?.text.contains("[[s3]]") == true }) else {
                        check(false, "spaces: ⌘T Ask starts s3 in Space B"); return done()
                    }
                    follow(r3, "s3")
                    add("s3", r3)
                    check(model.run === r3 && pane.isShown, "spaces: ⌘T Ask in Space B: the pane shows the new task s3 (\(shown()))")
                    toSpace(a, aSpace, "cmd+opt+left") { [self] how in
                        check(model.run === r1, "spaces: Space A still shows s1 after B's ⌘T Ask (\(shown())) [\(how)]")
                        // ⌥↩ in A: in the background; A's pane stays on s1.
                        fake("s4", 4, 4)
                        CommandBarView.startAgentTask("Count on tally page 4 [[s4]]", attached: [], in: a, background: true)
                        wait({ AgentTaskCenter.shared.runs.contains { $0.steps.first?.text.contains("[[s4]]") == true } }, 4) { [self] in
                            if let r4 = AgentTaskCenter.shared.runs.first(where: { $0.steps.first?.text.contains("[[s4]]") == true }) {
                                follow(r4, "s4")
                                add("s4", r4)
                            } else { check(false, "spaces: ⌥↩ starts s4 in Space A") }
                            check(model.run === r1, "spaces: ⌥↩ in Space A starts s4 in the background; the pane stays on s1 (\(shown()))")
                            toSpace(a, bSpace, "cmd+opt+right") { [self] how in
                                check(model.run === r3, "spaces: Space B: s3 (\(shown())) [\(how)]")
                                // A new window (Space B): its own pane, empty.
                                let b = k.app.openNewWindow(from: a, spaceID: bSpace, commandBar: false)
                                after(1.0) { [self] in
                                    guard let b else { check(false, "spaces: a new window"); return done() }
                                    let pb = AgentPaneController.show(b)
                                    check(pb !== pane && pb.model.run.steps.isEmpty && pb.model.text.isEmpty,
                                          "spaces: a new window's pane starts on the empty state, not another window's task (\(pb.model.title))")
                                    check(model.run === r3, "spaces: … and the first window's pane keeps s3 (\(shown()))")
                                    b.window.close()
                                    a.window.makeKeyAndOrderFront(nil)
                                    after(0.8, done)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// After every task ended: the shown tasks are still each Space's; back to Space A.
    private func finishSpaces(_ a: WindowController, _ pane: AgentPaneController, _ aSpace: String, _ bSpace: String,
                              _ runs: [String: AgentRunCenter], shown: @escaping () -> String, _ done: @escaping () -> Void) {
        let model = pane.model
        toSpace(a, aSpace, "cmd+opt+left") { [self] how in
            check(model.run === runs["s1"], "spaces: finished, Space A still shows s1 (\(shown())) [\(how)]")
            toSpace(a, bSpace, "cmd+opt+right") { [self] how in
                check(model.run === runs["s3"], "spaces: finished, Space B still shows s3 (\(shown())) [\(how)]")
                toSpace(a, aSpace, "cmd+opt+left") { _ in done() }
            }
        }
    }

    // MARK: The field keeps the keyboard

    func caseFocus(_ done: @escaping () -> Void) {
        let a = home!
        AgentUI.close(a)
        a.closeCommandBar()
        a.navigate(to: URL(string: "\(base)/home.html")!, newTab: true)
        a.window.makeKeyAndOrderFront(nil)
        var log: [String] = []
        let before = AgentCenter.shared.onEvent
        AgentCenter.shared.onEvent = { e in log.append(e); before?(e) }
        func field() -> Bool { AgentPaneController.pane(of: a)?.fieldHasKeys == true }
        func responder() -> String { a.window.firstResponder.map { String(describing: type(of: $0)) } ?? "none" }
        func finish() { AgentCenter.shared.onEvent = before; AgentUI.close(a); after(0.4, done) }
        after(1.2) { [self] in
            // 1. The page takes the keys back 0.3 s after the pane opened: the field gets them back.
            togglePane(a) { [self] how in
                check(field(), "panefocus: ⌥⌘A opens the pane with the keys in its field (\(responder())) [\(how)]")
                a.focusShownPage()
                let took = !field()
                after(0.5) { [self] in
                    check(took && field() && log.contains { $0.hasPrefix("pane-focus") },
                          "panefocus: the page took the keys back after the pane opened: the field has them again (\(responder()); \(log.filter { $0.hasPrefix("pane-focus") }.last ?? "no reassert"))")
                    // 2. A page that keeps taking them wins after a few tries.
                    var n = 0
                    func grab() {
                        a.focusShownPage()
                        n += 1
                        if n < 6 { after(0.12, grab) } else { after(0.6, settle) }
                    }
                    func settle() {
                        let count = log.filter { $0.hasPrefix("pane-focus") }.count
                        check(!field() && count <= AgentPaneFieldKeep.maxReasserts,
                              "panefocus: a page that keeps taking the keys keeps them after \(count) tries (no tug of war; \(responder()))")
                        AgentUI.close(a)
                        after(0.6) { [self] in personClick(a, field: field, responder: responder, finish) }
                    }
                    grab()
                }
            }
        }
    }

    /// 3. The person clicks the page right after the pane opened: the keys stay on the page.
    private func personClick(_ a: WindowController, field: @escaping () -> Bool, responder: @escaping () -> String, _ done: @escaping () -> Void) {
        guard k.real, let page = a.shownTabID.flatMap({ a.engineTab(for: $0) })?.view, let main = NSScreen.screens.first else {
            note("agentparallel \(engine): panefocus: the person's click needs real input; not run (posted)")
            return done()
        }
        togglePane(a) { [self] how in
            check(field(), "panefocus: the pane opens again with the keys in its field [\(how)]")
            let r = a.window.convertToScreen(page.convert(page.bounds, to: nil))
            UIDriverClient.run(["--click", "\(Int(r.minX + 60))", "\(Int((main.frame.maxY - (r.maxY - 80)).rounded()))"]) { [self] ok, out in
                DispatchQueue.main.async { [self] in
                    // Then the page refocuses itself (as in case 1): the person's click came first, so it stays there.
                    a.focusShownPage()
                    after(1.0) { [self] in
                        if !ok { note("FAIL-ENV agentparallel \(engine): panefocus: the driver refused the click (\(out))"); return done() }
                        check(!field(), "panefocus: a real click on the page right after opening leaves the keys on the page (\(responder()))")
                        done()
                    }
                }
            }
        }
    }
}
#endif
