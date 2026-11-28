// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// aidemo4's finding (2026-11-26), part of `--script agentmain` (`AIRC_AGENTMAIN_ONLY=blank`): a new task's tab, before
/// its first page (the model's first turn holds 2.5 s, as a real model's does), shows the card's own fill with
/// "Starting…", never the blank page's white, and its Today row is titled with the task, never "about:blank"; once the
/// first page has loaded, the page's own pixels and title.
extension AgentMainCheck {
    func caseBlank(_ done: @escaping () -> Void) {
        let task = "Count the tally once"
        k.start("blank", [.toolThenHold("wait", ["duration": 1], hold: 2.5), .tool("navigate", ["url": "\(base)/am-shop.html"]),
                          .toolThenHold("wait", ["duration": 4], hold: 0.5), .text("Done.")], task: task)
        var white = 0, samples = 0, covered = 0, rows: Set<String> = []
        var sampling = true
        func tick() {
            guard sampling else { return }
            if let e = entry, c.shownTabID == e.tabID, let page = e.page, page.url?.host == nil {
                samples += 1
                if let p = pagePicture(), look(p, want: nil).white > 0.5 { white += 1 }
                if chrome?.starting == true { covered += 1 }
                rows.insert(c.store.tab(e.tabID)?.title ?? "")
            }
            after(0.05, tick)
        }
        wait({ self.entry != nil }, 15) { [self] in
            tick()
            wait({ self.k.events.contains("tool navigate") }, 15) { [self] in
                sampling = false
                check(samples >= 10, "blank: the task's new tab was sampled before its first page (\(samples) samples)")
                check(white == 0, "blank: … never white in the main view (\(white) of \(samples) samples ≥ 50 % white)")
                check(covered == samples, "blank: … the card's fill with “Starting…” over it (\(covered) of \(samples))")
                let title = AgentTaskTitle.make(task)
                check(rows == [title], "blank: … its Today row says the task (“\(rows.sorted().joined(separator: "”, “"))”), never about:blank")
                wait({ self.chrome?.starting == false && self.entry?.page?.isLoading == false }, 10) { [self] in
                    after(0.4) { [self] in
                        if let p = pagePicture() {
                            let l = look(p, want: (0x1e, 0x8c, 0x7a))
                            check(l.match > 0.5 && l.white < 0.2, "blank: once the first page has loaded, the page's own pixels (teal \(Int(l.match * 100)) %, white \(Int(l.white * 100)) %)")
                        } else { note("FAIL-ENV agentmain \(engine): blank: no window-server picture") }
                        let t = entry.flatMap { c.store.tab($0.tabID)?.title } ?? ""
                        check(t.hasPrefix("Tally") || t.hasPrefix("Counted"), "blank: … and the row takes the page's title (“\(t)”)")
                        k.untilIdle(15) { done() }
                    }
                }
            }
        }
    }

    /// agentpanescope (shotask2's finding): ⌘T → "Ask Airc to…" → Return with Codex (the fake `codex`, its first turn
    /// held 2.5 s as a real one's start is): the new task's Today row has the task's name from the first frame it exists
    /// (sampled every ~16 ms), never "about:blank" or an address, until the page's own title arrives.
    /// agentparkclick (aidemo5: the store was right, the drawn row read "about:blank" ~0.8 s on the shown path): also the
    /// row's drawn label, and ⌘T and the typing are real keys in a dedicated session.
    func caseBlankAsk(_ done: @escaping () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-blankask-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, source) in [("claude", AgentCLIFakes.claude), ("codex", AgentCLIFakes.codex)] {
            let u = dir.appendingPathComponent(n)
            try? source.write(to: u, atomically: true, encoding: .utf8)
            chmod(u.path, 0o755)
        }
        let turns: [[[String: Any]]] = [[["hold": 2.5], ["tool": "navigate", "args": ["url": "\(base)/am-shop.html"]],
                                         ["tool": "wait", "args": ["duration": 1]], ["say": "Done."]]]
        if let d = try? JSONSerialization.data(withJSONObject: ["case": "blankask", "loggedIn": true, "turns": turns]) {
            try? d.write(to: dir.appendingPathComponent("fake-state.json"), options: .atomic)
        }
        AgentCLIDetector.shared.setDirForTesting(dir.path)
        AgentModelSettings.shared.update { $0.backend = .codex }
        func restore() {
            AgentModelSettings.shared.update { $0.backend = .apiKey }
            AgentCLIDetector.shared.setDirForTesting(k.cliNone.path)
        }
        let task = "Count the tally at the corner shop"
        let title = AgentTaskTitle.make(task)
        AgentCLIDetector.shared.check(.codex, maxAge: 0) { [self] st in
            guard st.isReady else { check(false, "blankask: the fake Codex is ready (\(st.summary(.codex)))"); restore(); return done() }
            AgentPaneController.pane(of: c)?.close()
            c.closeCommandBar()
            c.window.makeKeyAndOrderFront(nil)
            let before = Set(c.store.state.tabs.keys)
            var rows: [String] = [], firstRow: String?, sampling = true, tabID: String?
            var drawn: [String] = [], firstDrawn: String?, input = "posted"
            func label(_ id: String) -> String? {
                c.pageView(for: c.currentSpaceID)?.rows.values.lazy.compactMap { $0 as? TabRowView }.first { $0.tabID == id }?.spokenTitle
            }
            func tick() {
                guard sampling else { return }
                if tabID == nil { tabID = c.store.state.tabs.values.first { !before.contains($0.id) && $0.isToday }?.id }
                if let id = tabID, let t = c.store.tab(id) {
                    // What the row shows (an empty title shows the address).
                    if firstRow == nil { firstRow = t.displayTitle }
                    if rows.last != t.displayTitle { rows.append(t.displayTitle) }
                    // What the row draws (the live page's title wins over the store's for a shown page).
                    if let l = label(id) {
                        if firstDrawn == nil { firstDrawn = l }
                        if drawn.last != l { drawn.append(l) }
                    }
                }
                after(0.016, tick)
            }
            func openBar(_ then: @escaping () -> Void) {
                guard k.real, c.window.isKeyWindow, NSApp.isActive else { c.openCommandBar(mode: .newTab); return after(0.3, then) }
                k.key("cmd+t") { [self] ok in
                    after(0.4) { [self] in
                        if !ok || c.commandBar == nil { c.openCommandBar(mode: .newTab) } else { input = "real ⌘T" }
                        then()
                    }
                }
            }
            func typeTask(_ then: @escaping () -> Void) {
                guard input != "posted", let keys = UIDriverClient.keys(typing: task) else { c.commandBar?.type(task); return after(0.6, then) }
                UIDriverClient.press(keys, pid: getpid()) { [self] ok, _ in
                    DispatchQueue.main.async { [self] in
                        if ok { input += " + typing" } else { c.commandBar?.type(task) }
                        after(0.6, then)
                    }
                }
            }
            openBar { typeTask { [self] in
                    let results = c.commandBar?.results ?? []
                    guard let i = results.firstIndex(where: { $0.title == CommandBarView.agentRowTitle }) else {
                        check(false, "blankask: ⌘T offers “Ask Airc to…” (\(results.map(\.title).joined(separator: " | ")))")
                        c.closeCommandBar(); restore(); return done()
                    }
                    var downs = i
                    func next() {
                        guard downs > 0 else {
                            tick()
                            return k.barKey("return") { [self] in
                                wait({ self.entry?.page.map { $0.url?.host != nil && !$0.title.isEmpty && $0.title != "about:blank" } == true }, 20) { [self] in
                                    after(0.3) { [self] in
                                        sampling = false
                                        let blankish = rows.filter { $0.isEmpty || $0.hasPrefix("about:") || $0.hasPrefix("http") || $0.contains("127.0.0.1") }
                                        check(run.cliKind == .codex, "blankask: the task runs on Codex (\(run.cliKind?.rawValue ?? "no CLI")) [\(k.real ? "real keys" : "posted keys")]")
                                        check(firstRow == title, "blankask: ⌘T Ask → Codex: the new Today row has the task's name from its first frame (“\(firstRow ?? "no row")”)")
                                        check(blankish.isEmpty && rows.first == title, "blankask: … never about:blank or an address before the page's title (rows: “\(rows.joined(separator: "” → “"))”)")
                                        let drawnBlank = drawn.filter { $0.isEmpty || $0.hasPrefix("about:") || $0.hasPrefix("http") || $0.contains("127.0.0.1") }
                                        check(firstDrawn == title && drawnBlank.isEmpty && !drawn.isEmpty,
                                              "blankask: … and the row the person sees draws the task's name from its first frame, never about:blank or an address (drawn: “\(drawn.joined(separator: "” → “"))”) [\(input)]")
                                        let t = entry.flatMap { c.store.tab($0.tabID)?.title } ?? ""
                                        check(t.hasPrefix("Tally") || t.hasPrefix("Counted"), "blankask: … then the page's own title (“\(t)”)")
                                        k.untilIdle(15) { restore(); done() }
                                    }
                                }
                            }
                        }
                        downs -= 1
                        k.barKey("down", next)
                    }
                    next()
                } }
        }
    }
}
#endif
