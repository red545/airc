// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import ObjectiveC

/// `--script cbflicker` (owner bugs, 0.1.18 and 0.1.26): the Command Bar's rows must not hide and show while you type,
/// and no row may beep or leave the keyboard nowhere when chosen.
///
/// Typing passes. Live suggestions on, as a real user has them, from a loopback stand-in (SearchEngineStandIn) that
/// answers each query after 30–150 ms. A word is typed one key at a time; every time the bar makes its rows
/// (`onRowsReloaded`: what the next frame shows) the rows are recorded. FAIL on:
///   - a state with 0 suggestion rows once they've shown, while the words have ≥ 2 letters;
///   - a conditional row (the prompt's "Ask Claude" row, "Ask Airc to…", the Ask AI command) that goes away again after
///     it showed (toggling with the "looks like a prompt" guess or the second letter);
///   - rows above the selection's block moving between keys: once shown, the search row and the Ask rows keep their
///     places from key to key;
///   - a final list that isn't the last answer.
/// Cases: the built-in engine (real keys, fast keys, slow keys); an imported default engine with its own suggest_url (as
/// an Arc/Chrome import makes it, C08) answering from the same delayed fixture; prompt typing ("how do i make fresh
/// pasta") with Ask AI on Claude, with and without an agent key.
///
/// Choosing passes (the 0.1.26 beep): "ask page", a prompt's Ask rows and the Ask AI command are chosen with ↓ and
/// Return. FAIL on any beep (Airc's own, or AppKit's "no responder"), when nothing visible happens, when the next key
/// typed lands in no text field, or when Esc then beeps. States: no agent key, Ask on Page off, Ask on Page on (on this
/// Mac with or without Apple Intelligence), Automatic with no AI site, a private window.
///
/// Real keys with AIRC_REAL_KEYS=1 (the stable UI driver, PID-targeted). `AIRC_CB_KEEP_SUGGESTIONS=0` brings back the
/// old clearing (it must fail); `AIRC_CB_STABLE_ROWS=0` the 0.1.26 placement of the conditional rows.
extension SnapshotRunner {
    func commandBarFlickerCheck() {
        let tag = app?.engine is WebKitEngine ? "cbflicker (WebKit)" : "cbflicker (Chromium)"
        var server: LocalPageServer?
        var port: UInt16 = 0
        let lock = NSLock()
        var answered = 0
        var bar: CommandBarView? { self.c.commandBar }
        let real = UIDriverClient.requested
        let profile = { self.c.store.profile(ofSpace: self.c.currentSpaceID) }
        let prompt = "how do i make fresh pasta"
        struct RowsState { var q: String; var sugg: Int; var kinds: [String]; var titles: [String] }
        var states: [RowsState] = []
        var recording = false
        var savedSites: SiteSearchSettings?
        let agentKey = "airc-fixture-model-key-cbflicker"
        let agentBase = { "http://127.0.0.1:\(port)/model" }
        func base() -> String { "http://127.0.0.1:\(port)" }

        /// The stand-in's answer: three suggestions that start with the words (an imported engine's also repeats the
        /// words first, as Google's does; the parser drops that).
        func answer(_ q: String) -> [String] { [q + " forecast", q + " today", q + " radar"] }

        /// What a row is, for the stability rules.
        func kind(_ r: CommandResult, _ q: String) -> String {
            let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.title == CommandBarView.agentRowTitle { return "agent" }
            if r.badge == "Ask" && r.subtitle == t { return "ask" }
            if r.badge == "Run" && (r.title == "New ChatGPT Message" || (r.title.hasPrefix("Ask ") && r.title.hasSuffix("…"))) { return "askcmd" }
            if r.badge == "Search" && r.subtitle.isEmpty { return "sugg" }
            if r.badge == "Search" && r.title == t { return "search" }
            return r.badge.lowercased()
        }

        func press(_ name: String, code: UInt16, chars: String, window: @escaping () -> NSWindow? = { nil }) {
            step { [self] done in
                if real {
                    UIDriverClient.press([name], pid: getpid()) { ok, out in
                        if !ok { self.note("FAIL-ENV \(tag) [real keys] \(name): \(out)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
                    }
                    return
                }
                let w = window() ?? NSApp.keyWindow ?? c.window
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: code == 125 ? [.numericPad, .function] : [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                    NSApp.sendEvent(e)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
            }
        }
        func down() { press("down", code: 125, chars: "\u{F701}") }
        func returnKey() { press("return", code: 36, chars: "\r") }
        func escape() { press("escape", code: 53, chars: "\u{1B}") }
        func waitFor(_ timeout: Double = 4, _ condition: @escaping () -> Bool) {
            step { [self] done in waitUntil(condition, timeout: timeout, then: done) }
        }
        /// One key of text, real or through the field editor (posted).
        func typeKey(_ ch: Character, label: String, gap: Double, realKeys: Bool) {
            step { [self] done in
                if realKeys {
                    UIDriverClient.press(UIDriverClient.keys(typing: String(ch)) ?? [String(ch)], pid: getpid()) { ok, out in
                        if !ok { self.note("FAIL-ENV \(tag) [real keys] \(label) “\(ch)”: \(out)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + gap, execute: done)
                    }
                } else {
                    if let b = bar { b.type(b.query + String(ch)) } else if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                        tv.insertText(String(ch), replacementRange: tv.selectedRange())
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + gap, execute: done)
                }
            }
        }

        // Beeps: Airc's own (AppPersonalization, sounds on or off) and AppKit's for a key nothing took.
        Self.installNoResponderProbe()
        var beeps: Int { Self.noResponderBeeps + AppPersonalization.silencedBeeps + Self.ownBeeps }
        AppPersonalization.testBeep = { Self.ownBeeps += 1 }

        if real { activateForRealInput() }
        step { done in
            server = LocalPageServer(responses: [:])
            server?.handler = { path in
                switch path {
                case "/claude/new": LocalPageServer.Page(body: "<!doctype html><title>Loop Claude</title><p>new chat</p>")
                default: LocalPageServer.Page(body: "<!doctype html><title>cbflicker page</title><p>A page with some words to ask about: fresh pasta needs flour and eggs.</p>")
                }
            }
            var n = 0
            server?.requestHandler = { r in
                if r.target.hasPrefix("/model") { return LocalPageServer.Page(status: "500 Internal Server Error", body: "{}") }
                guard !r.target.hasPrefix("/claude"), r.target.contains("q="),
                      let raw = URLComponents(string: "http://x" + r.target)?.queryItems?.first(where: { $0.name == "q" })?.value
                else { return nil }
                // A server reads "+" as a space (an imported template's encoding); URLComponents doesn't.
                let q = raw.replacingOccurrences(of: "+", with: " ")
                // 30–150 ms, varied: the answer comes after a real engine's usual delay.
                n += 1
                lock.withLock { answered += 1 }
                let imported = r.target.hasPrefix("/suggest.example.com/")
                let list = ((imported ? [q] : []) + answer(q)).map { "\"\($0)\"" }.joined(separator: ",")
                return LocalPageServer.Page(headers: ["Content-Type": "application/json"], body: "[\"\(q)\",[\(list)]]",
                                            delay: Double(30 + n * 37 % 121) / 1000)
            }
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            check(port != 0, "\(tag): loopback suggestion endpoint listens")
            SearchEngineStandIn.origin = base()
            AskAIRoute.testTemplates = [.claude: base() + "/claude/new?q=%s"]
            app?.settings.values.suggestionsEnabled = true
            savedSites = app?.settings.values.siteSearch
            AgentModelSettings.shared.setTestKey(nil, provider: .anthropic, base: agentBase())
            if !real { Self.emulateKeyWindow(c) { [weak self] in self?.note($0) } }
            note("\(tag): real keys \(real), keep suggestions \(CommandBarView.keepsSuggestions), stable rows \(CommandBarView.stableRows), "
                 + "app active \(NSApp.isActive), key window \(c.window.isKeyWindow), load \(Self.loadAverage())")
        }

        // MARK: Typing passes

        func pass(_ label: String, word: String, gap: Double, realKeys: Bool, suggestions: Bool = true,
                  expected: [String]? = nil) {
            run { [self] in
                c.closeCommandBar()
                c.openCommandBar(mode: .newTab)
                states = []
                recording = true
                bar?.onRowsReloaded = { b in
                    guard recording else { return }
                    states.append(RowsState(q: b.query, sugg: b.suggestionRowCount, kinds: b.results.map { kind($0, b.query) },
                                            titles: b.results.map(\.title)))
                }
            }
            wait(0.2)
            for ch in word { typeKey(ch, label: label, gap: gap, realKeys: realKeys) }
            if suggestions {
                step { [self] done in
                    waitUntil({ bar?.suggestionRowCount ?? 0 > 0 && bar?.results.contains { $0.title == answer(word)[0] } == true }, timeout: 3, then: done)
                }
            } else {
                wait(0.5)
            }
            run { [self] in
                recording = false
                bar?.onRowsReloaded = nil
                let typedAll = bar?.query == word
                note("\(tag) \(label): rows states \(states.count), answers so far \(lock.withLock { answered })")
                for s in states { note("  \(s.q): \(s.sugg) [\(s.kinds.joined(separator: " "))]") }
                check(typedAll, "\(tag) \(label): “\(word)” typed (field “\(bar?.query ?? "-")”)")
                if suggestions {
                    // From the first state with suggestions on, while the words have two letters or more.
                    let start = states.firstIndex { $0.sugg > 0 } ?? states.count
                    let after = states[start...].filter { $0.q.count >= 2 }
                    let empty = after.filter { $0.sugg == 0 }
                    check(start < states.count && empty.isEmpty,
                          "\(tag) \(label): suggestion rows never drop to 0 while typing (\(empty.count) of \(after.count) states had none: \(empty.map(\.q)))")
                    let shown = bar?.results.filter { $0.badge == "Search" && $0.subtitle.isEmpty }.map(\.title) ?? []
                    check(shown == (expected ?? answer(word)), "\(tag) \(label): the last answer's suggestions are shown (\(shown))")
                }
                // Conditional rows: once shown while the words grow, they stay.
                for k in ["ask", "agent", "askcmd"] {
                    var on = false, drops: [String] = []
                    for s in states where s.q.count >= 2 {
                        let has = s.kinds.contains(k)
                        if on && !has { drops.append(s.q) }
                        if has { on = true }
                    }
                    check(drops.isEmpty, "\(tag) \(label): the “\(k)” row doesn't come and go between keys (gone again at \(drops))")
                }
                // Rows above: once the prompt's rows show, they and the search row above them keep their places from key
                // to key (what's above them is the search row and one row: two arrows down).
                var moved: [String] = []
                for (a, b) in zip(states, states.dropFirst()) where a.kinds.contains("ask") || a.kinds.contains("agent") {
                    for k in ["search", "ask", "agent"] {
                        guard let i = a.kinds.firstIndex(of: k), let j = b.kinds.firstIndex(of: k), i != j else { continue }
                        moved.append("\(k) \(i)→\(j) at “\(b.q)”")
                    }
                }
                check(moved.isEmpty, "\(tag) \(label): rows above the selection's block don't move between keys once the prompt's rows show (\(moved))")
                c.closeCommandBar()
            }
        }

        // 1. The built-in engine.
        if real { pass("built-in, real keys", word: "weather", gap: 0.05, realKeys: true) }
        pass("built-in, fast keys", word: "lisbon trams", gap: 0.04, realKeys: false)
        pass("built-in, slow keys", word: "vienna", gap: 0.25, realKeys: false)

        // 2. An imported default engine with its own endpoint (an Arc/Chrome import, C08).
        run { [self] in
            guard var s = app?.settings.values.siteSearch else { return check(false, "\(tag): settings") }
            _ = s.apply(SearchEngineImport(
                defaultSearch: .site(.init(name: "Loop Find", keyword: "lf", template: "https://find.example.com/search?q=%s",
                                           suggest: "https://suggest.example.com/ac?q={searchTerms}")),
                shortcuts: []), to: profile().id)
            app?.settings.values.siteSearch = s
            check(profile().defaultSearch.site?.suggestTemplate != nil, "\(tag): the imported default has its own suggest endpoint")
        }
        if real { pass("imported engine, real keys", word: "weather", gap: 0.05, realKeys: true) }
        pass("imported engine, fast keys", word: "lisbon trams", gap: 0.04, realKeys: false)
        pass("imported engine, slow keys", word: "vienna", gap: 0.25, realKeys: false)
        run { [self] in if let savedSites { app?.settings.values.siteSearch = savedSites } }

        // 3. Prompt typing: Ask AI on Claude; no agent key, then a key.
        run { [self] in app?.settings.values.askAI.set(.provider(.claude), for: profile().id) }
        pass("prompt, no key", word: prompt, gap: real ? 0.05 : 0.12, realKeys: real)
        run { AgentModelSettings.shared.setTestKey(agentKey, provider: .anthropic, base: agentBase()) }
        pass("prompt, key", word: prompt, gap: real ? 0.05 : 0.12, realKeys: real)
        run { AgentModelSettings.shared.setTestKey(nil, provider: .anthropic, base: agentBase()) }
        run { [self] in
            c.openCommandBar(mode: .newTab)
            bar?.type(prompt)
        }
        wait(0.6)
        run { [self] in
            let titles = bar?.results.map(\.title) ?? []
            check(titles.contains(CommandBarView.agentRowTitle), "\(tag): no key: a prompt still offers “Ask Airc to…” (\(titles))")
            c.closeCommandBar()
        }

        // MARK: Choosing passes

        /// A page to ask about, shown.
        step { [self] done in
            c.navigate(to: URL(string: base() + "/page")!, newTab: true)
            waitUntil({ self.c.shownTabID.flatMap { self.c.engineTab(for: $0) }?.isLoading == false }, timeout: 8, then: done)
        }

        /// Opens the bar, types `text` with real keys, selects the row `pick` finds (↓ presses), Return; then checks no
        /// beep, that something happened (`effect`), that the next key lands in a text field, and Esc.
        func choose(_ label: String, type text: String, pick: @escaping ([CommandResult]) -> Int?, optional: Bool = false,
                    opensPage: Bool = false, effect: @escaping () -> String?) {
            var before = 0, tabsBefore = 0, index: Int?
            run { [self] in
                c.closeCommandBar()
                AgentUI.close(c)
                if c.findBar != nil { c.closeFind(refocusPage: true) }
                c.window.makeKeyAndOrderFront(nil)
                c.openCommandBar(mode: .newTab)
            }
            wait(0.3)
            for ch in text { typeKey(ch, label: label, gap: 0.03, realKeys: real) }
            wait(0.6)
            step { [self] done in
                index = pick(bar?.results ?? [])
                let rows = bar?.resultTitles.joined(separator: " | ") ?? "-"
                note("\(tag) choose \(label): rows \(rows); picked \(index.map(String.init) ?? "none")")
                if index == nil {
                    if !optional { check(false, "\(tag) choose \(label): the row is offered (\(rows))") }
                    c.closeCommandBar()
                }
                before = beeps
                tabsBefore = c.store.state.tabs.count
                done()
            }
            step { [self] done in
                guard let i = index else { return done() }
                var downs = i
                func next() {
                    guard downs > 0 else { return done() }
                    downs -= 1
                    if real {
                        UIDriverClient.press(["down"], pid: getpid()) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: next) }
                    } else {
                        bar?.moveSelectionForTesting(by: 1)
                        next()
                    }
                }
                next()
            }
            step { [self] done in
                guard let i = index else { return done() }
                check(bar?.selected == i, "\(tag) choose \(label): ↓×\(i) selects it (\(bar?.selected ?? -1))")
                done()
            }
            step { [self] done in
                guard index != nil else { return done() }
                if real {
                    UIDriverClient.press(["return"], pid: getpid()) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: done) }
                } else {
                    bar?.executeSelectedForTesting()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: done)
                }
            }
            step { [self] done in
                guard index != nil else { return done() }
                let what = effect() ?? (c.store.state.tabs.count > tabsBefore ? "a new tab" : nil)
                check(beeps == before, "\(tag) choose \(label): Return doesn't beep (\(beeps - before) beeps)")
                check(what != nil, "\(tag) choose \(label): Return does something (\(what ?? "nothing happened"))")
                let fr = NSApp.keyWindow?.firstResponder
                note("\(tag) choose \(label): key window \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"), first responder \(fr.map { String(describing: type(of: $0)) } ?? "none")")
                before = beeps
                done()
            }
            // The next key lands in a text field: the bar's, the Ask on Page field, the agent panel's. (A row that opens
            // a page leaves the keyboard on the page, where a WebKit page beeps for a key nothing takes, as Safari does.)
            step { [self] done in
                guard index != nil, !opensPage else { return done() }
                let window = NSApp.keyWindow
                let tv = window?.firstResponder as? NSTextView
                let textBefore = tv?.string ?? ""
                func after() {
                    let now = (window?.firstResponder as? NSTextView)?.string ?? ""
                    check(beeps == before, "\(tag) choose \(label): typing after it doesn't beep (\(beeps - before))")
                    check(tv != nil && now == textBefore + "z",
                          "\(tag) choose \(label): the next key is typed into a text field (“\(textBefore)” → “\(now)”, \(tv == nil ? "no text field has the keyboard" : "field editor"))")
                    before = beeps
                    done()
                }
                if real {
                    UIDriverClient.press(UIDriverClient.keys(typing: "z") ?? ["z"], pid: getpid()) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: after) }
                } else {
                    tv?.insertText("z", replacementRange: tv?.selectedRange() ?? NSRange(location: 0, length: 0))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: after)
                }
            }
            step { [self] done in
                guard index != nil, !opensPage else { return done() }
                func after() {
                    check(beeps == before, "\(tag) choose \(label): Esc doesn't beep (\(beeps - before))")
                    done()
                }
                if real {
                    UIDriverClient.press(["escape"], pid: getpid()) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: after) }
                } else {
                    NSApp.keyWindow?.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: after)
                }
            }
            run { [self] in
                c.closeCommandBar()
                AgentUI.close(c)
                if c.findBar != nil { c.closeFind(refocusPage: true) }
                // Back to the page tab the next case asks about.
                if let id = c.store.state.tabs.values.first(where: { $0.url.hasPrefix(base() + "/page") })?.id, c.shownTabID != id { c.show(id) }
            }
            wait(0.4)
        }
        let asking = { () -> String? in
            guard let f = self.c.findBar, f.isAsking else { return nil }
            let card = MainActor.assumeIsolated { AskPageFeature.session(of: self.c)?.card }
            let said = MainActor.assumeIsolated { card?.answerLabel.stringValue ?? "" }
            let button = MainActor.assumeIsolated { card?.settingsButton.isHidden == false }
            return "Ask on Page (\(card?.refusal != nil ? "says: \(said)\(button ? " + Open Settings › AI" : "")" : "asking"))"
        }
        let panelOpen = { () -> String? in AgentUI.isShown(self.c) ? "the Airc Agent pane" : nil }
        let barAsking = { () -> String? in
            if case .ask(let p)? = self.c.commandBar?.scope { return "the bar asking \(p.name)" }
            return nil
        }
        func top(_ r: [CommandResult]) -> Int? { r.isEmpty ? nil : 0 }

        // "ask page", the owner's words: Ask on Page off (the default), then on.
        run { [self] in app?.settings.values.askPage = false }
        choose("“ask page”, Ask on Page off, top row", type: "ask page", pick: top, opensPage: true) { asking() ?? panelOpen() ?? barAsking() }
        choose("“ask page”, Ask on Page off, Ask on Page row", type: "ask page",
               pick: { $0.firstIndex { $0.title.hasPrefix("Ask This Page") || $0.title.hasPrefix("Ask on Page") } }) { asking() }
        run { [self] in app?.settings.values.askPage = true }
        choose("“ask page”, Ask on Page on, top row", type: "ask page", pick: top, opensPage: true) { asking() ?? panelOpen() ?? barAsking() }
        choose("“ask page”, Ask on Page on, Ask This Page…", type: "ask page",
               pick: { $0.firstIndex { $0.title.hasPrefix("Ask This Page") || $0.title.hasPrefix("Ask on Page") } }) { asking() }
        // This Mac with Apple Intelligence (the fake model, as askpage's): off, the card says it's off; on, it asks.
        let askModel = ScriptedAskModel()
        run { [self] in
            app?.settings.values.askPage = false
            MainActor.assumeIsolated {
                AIFeatures.shared.testOverride = (.available, nil)
                AIFeatures.shared.testModels = .init(ask: askModel)
            }
        }
        choose("“ask page”, Apple Intelligence, Ask on Page off", type: "ask page",
               pick: { $0.firstIndex { $0.title.hasPrefix("Ask This Page") } }) {
            guard let a = asking() else { return nil }
            self.check(a.contains("is off") && a.contains("Open Settings"), "\(tag): with Apple Intelligence, Ask on Page off says it's off, with the way to Settings (\(a))")
            return a
        }
        run { [self] in
            let note = MainActor.assumeIsolated { AskPageFeature.session(of: c)?.card.answerLabel.stringValue }
            self.note("\(tag): Ask on Page off with Apple Intelligence says: \(note ?? "-")")
        }
        run { [self] in app?.settings.values.askPage = true }
        wait(0.3)
        choose("“ask page”, Apple Intelligence, Ask on Page on", type: "ask page",
               pick: { $0.firstIndex { $0.title.hasPrefix("Ask This Page") } }) { asking() }
        run { [self] in
            app?.settings.values.askPage = false
            MainActor.assumeIsolated {
                AIFeatures.shared.testModels = nil
                AIFeatures.shared.testOverride = nil
            }
        }
        // A prompt's rows, Claude chosen, no agent key.
        choose("prompt, Ask Claude row", type: "how do i boil eggs", pick: { $0.firstIndex { $0.badge == "Ask" } }, opensPage: true) {
            self.c.shownTabID.flatMap { self.c.store.tab($0) }.map { $0.url.contains("/claude/new") ? "a Claude tab" : nil } ?? nil
        }
        choose("prompt, Ask Airc to… (no key)", type: "how do i boil eggs",
               pick: { $0.firstIndex { $0.title == CommandBarView.agentRowTitle } }) { panelOpen() }
        run { [self] in
            let draft = AgentUI.draftForTesting(c)
            note("\(tag): agent panel draft after the no-key case: \(draft ?? "none")")
        }
        choose("Ask Claude… command", type: "ask cl",
               pick: { $0.firstIndex { $0.badge == "Run" && $0.title == "Ask Claude…" } }) { barAsking() }
        // Automatic with no AI site used: no Ask row; whatever row is first still works.
        run { [self] in
            app?.settings.values.askAI.set(.automatic, for: profile().id)
            AskAIAutomatic.forget()
        }
        choose("prompt, Automatic with no AI site, top row", type: "how do i boil eggs", pick: top, opensPage: true) {
            self.c.shownTabID.flatMap { self.c.store.tab($0) }.map { $0.url.contains("find") || $0.url.contains("q=") ? "a search tab" : nil } ?? nil
        }
        run { [self] in
            c.openCommandBar(mode: .newTab)
            bar?.type("how do i boil eggs")
        }
        wait(0.5)
        run { [self] in
            let ask = bar?.results.filter { $0.badge == "Ask" }.map(\.title) ?? []
            check(ask.isEmpty, "\(tag): Automatic with no AI site offers no Ask row (\(ask))")
            c.closeCommandBar()
        }

        // A private window: its Ask row opens the question there, and nothing beeps.
        step { [self] done in
            guard let app else { return done() }
            app.settings.values.askAI.set(.provider(.claude), for: profile().id)
            PrivateBrowsing.shared.open(app: app) { pw in
                guard let pw else { self.check(false, "\(tag) private: a private window opens"); return done() }
                pw.openCommandBar(mode: .newTab)
                pw.commandBar?.type("how do i boil eggs")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let rows = pw.commandBar?.results ?? []
                    let agent = rows.contains { $0.title == CommandBarView.agentRowTitle }
                    self.check(!agent, "\(tag) private: no “Ask Airc to…” row in a private window")
                    let before = beeps, pages = pw.pages.count
                    if let i = rows.firstIndex(where: { $0.badge == "Ask" }) {
                        for _ in 0..<i { pw.commandBar?.moveSelectionForTesting(by: 1) }
                        pw.commandBar?.executeSelectedForTesting()
                    } else {
                        self.check(false, "\(tag) private: the Ask row is offered (\(rows.map(\.title)))")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.check(beeps == before && pw.pages.count > pages,
                                   "\(tag) private: the Ask row opens a tab, no beep (\(beeps - before) beeps, pages \(pages)→\(pw.pages.count))")
                        pw.closeWindow()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
                    }
                }
            }
        }

        // An address or one letter gets no suggestions: none are kept for it.
        run { [self] in
            app?.settings.values.askAI.set(.automatic, for: profile().id)
            c.openCommandBar(mode: .newTab)
            bar?.type("weather")
        }
        step { [self] done in waitUntil({ bar?.suggestionRowCount ?? 0 > 0 }, timeout: 3, then: done) }
        run { [self] in
            bar?.type("w")
            check(bar?.suggestionRowCount == 0, "\(tag): one letter keeps no suggestions (\(bar?.suggestionRowCount ?? -1))")
            bar?.type("example.com/weather")
            check(bar?.suggestionRowCount == 0, "\(tag): an address keeps no suggestions (\(bar?.suggestionRowCount ?? -1))")
            c.closeCommandBar()
            note("\(tag): beeps in all \(beeps) (AppKit no-responder \(Self.noResponderBeeps), Airc \(Self.ownBeeps), silenced \(AppPersonalization.silencedBeeps))")
            AppPersonalization.testBeep = nil
            AskAIRoute.testTemplates = [:]
            SearchEngineStandIn.origin = nil
            SuggestionService.shared.clear(profileID: profile().id)
            server?.stop()
        }
    }

    // MARK: Beep probe

    static var ownBeeps = 0
    static var noResponderBeeps = 0
    private static var noResponderProbeInstalled = false

    /// Counts AppKit's beep for a key nothing took (`-[NSWindow noResponderFor:]`, which calls NSBeep).
    static func installNoResponderProbe() {
        guard !noResponderProbeInstalled else { return }
        noResponderProbeInstalled = true
        let original = #selector(NSResponder.noResponder(for:))
        let probe = #selector(NSWindow.airc_cbNoResponder(for:))
        guard let inherited = class_getInstanceMethod(NSWindow.self, original) else { return }
        // NSWindow's own entry (added from what it inherits if it has none), so only windows are probed.
        class_addMethod(NSWindow.self, original, method_getImplementation(inherited), method_getTypeEncoding(inherited))
        guard let m1 = class_getInstanceMethod(NSWindow.self, original), let m2 = class_getInstanceMethod(NSWindow.self, probe) else { return }
        method_exchangeImplementations(m1, m2)
    }
}

extension NSWindow {
    /// Exchanged with `noResponder(for:)` by `installNoResponderProbe`: counts, then does AppKit's (this method's body is
    /// AppKit's by then).
    @objc func airc_cbNoResponder(for selector: Selector) {
        if selector == #selector(NSResponder.keyDown(with:)) { SnapshotRunner.noResponderBeeps += 1 }
        airc_cbNoResponder(for: selector)
    }
}
#endif
