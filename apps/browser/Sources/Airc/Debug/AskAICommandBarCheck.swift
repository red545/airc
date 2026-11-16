// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script askai` (feedback, 2026-11-16): in the Command Bar, a prompt gets an "Ask Claude" (or "Ask ChatGPT") row two
/// arrows down that opens a new chat with it. Claude and ChatGPT are loopback pages (`AskAIRoute.testTemplates`); no
/// account is used. With AIRC_REAL_KEYS=1 every key is a real driver key (PID-targeted), else the app's event path.
///   1. Settings → AI's default is Automatic, which is off for a profile that uses no chat site.
///   2. A recent claude.ai visit makes Automatic pick Claude. Typing a prompt shows "Ask Claude" third; ↓↓ selects it;
///      Return opens the loopback "claude.ai/new?q=<prompt>" in a new tab with the prompt encoded.
///   3. Searches, addresses, a host and words, and bangs get no Ask row.
///   4. ChatGPT chosen: "Ask ChatGPT", ↓↓, Return opens ChatGPT's loopback "/?q=<prompt>".
///   5. Off: the prompt gets no Ask row. Settings → AI shows the choice (PNG).
extension SnapshotRunner {
    func askAICommandBarCheck() {
        let webkit = app?.engine is WebKitEngine
        let tag = webkit ? "askai (WebKit)" : "askai (Chromium)"
        let real = UIDriverClient.requested
        var server: LocalPageServer?
        var port: UInt16 = 0
        var tabsBefore = Set<String>()
        var bar: CommandBarView? { self.c.commandBar }
        let profile = { self.c.store.profile(ofSpace: self.c.currentSpaceID) }
        let prompt = "why do lisbon trams have bells"
        let encoded = "why%20do%20lisbon%20trams%20have%20bells"
        func base() -> String { "http://127.0.0.1:\(port)" }
        func shownURL() -> String { c.engineTab(for: c.shownTabID ?? "")?.url?.absoluteString ?? "" }
        func newTabs() -> [LiveTab] { c.store.state.tabs.values.filter { !tabsBefore.contains($0.id) } }
        func rows() -> String { bar?.resultTitles.joined(separator: " | ") ?? "-" }
        func askIndex() -> Int? { bar?.results.firstIndex { $0.badge == "Ask" && $0.title.hasPrefix("Ask ") && $0.subtitle != "Press Tab" } }

        func openBar() {
            run { [self] in
                c.closeCommandBar()
                tabsBefore = Set(c.store.state.tabs.keys)
                c.openCommandBar(mode: .newTab)
            }
            wait(0.3)
        }

        /// Real keys: the driver types the text one key at a time (layout-aware). Otherwise the field gets it at once.
        func typeText(_ text: String) {
            step { [self] done in
                guard real else {
                    bar?.type(text)
                    return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
                guard let keys = UIDriverClient.keys(typing: text) else {
                    note("FAIL-ENV \(tag): the driver can't type “\(text)” on this layout"); return done()
                }
                UIDriverClient.press(keys, pid: getpid()) { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag) [real keys] typing: \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
            }
        }

        /// ↓ or Return: a real driver key, or one through the app's event path.
        func press(_ name: String, code: UInt16, chars: String) {
            step { [self] done in
                if real {
                    UIDriverClient.press([name], pid: getpid()) { ok, out in
                        if !ok { self.note("FAIL-ENV \(tag) [real keys] \(name): \(out)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
                    }
                    return
                }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: code == 125 ? [.numericPad, .function] : [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                    NSApp.sendEvent(e)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
            }
        }
        func down() { press("down", code: 125, chars: "\u{F701}") }
        func returnKey() { press("return", code: 36, chars: "\r") }
        func waitFor(_ timeout: Double = 4, _ condition: @escaping () -> Bool) {
            step { [self] done in waitUntil(condition, timeout: timeout, then: done) }
        }

        if real { activateForRealInput() }
        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.handler = { path in
                switch path {
                case "/claude/new": LocalPageServer.Page(body: "<!doctype html><title>Loop Claude</title><p>new chat</p>")
                case "/chatgpt/": LocalPageServer.Page(body: "<!doctype html><title>Loop ChatGPT</title><p>new chat</p>")
                default: LocalPageServer.Page(body: "<!doctype html><title>askai page</title><p>page</p>")
                }
            }
            // The profile's engine's suggestions (SearchEngineStandIn routes every engine here, as in cbflicker): three, after 60 ms.
            server?.requestHandler = { r in
                guard !r.path.hasPrefix("/claude"), !r.path.hasPrefix("/chatgpt"), r.target.contains("q="),
                      let q = URLComponents(string: "http://x" + r.target)?.queryItems?.first(where: { $0.name == "q" })?.value
                else { return nil }
                let list = [q + " meaning", q + " history", q + " facts"].map { "\"\($0)\"" }.joined(separator: ",")
                return LocalPageServer.Page(headers: ["Content-Type": "application/json"], body: "[\"\(q)\",[\(list)]]", delay: 0.06)
            }
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            check(port != 0, "\(tag): loopback chat sites listen")
            AskAIRoute.testTemplates = [.claude: base() + "/claude/new?q=%s", .chatGPT: base() + "/chatgpt/?q=%s"]
            // Live suggestions, as a person has them: the Ask row must stay two arrows down once they're in.
            SearchEngineStandIn.origin = base()
            app?.settings.values.suggestionsEnabled = true
            if !real { Self.emulateKeyWindow(c) { [weak self] in self?.note($0) } }
            note("\(tag): real keys \(real), app active \(NSApp.isActive), key window \(c.window.isKeyWindow), load \(Self.loadAverage())")

        }
        // MARK: 1. Automatic, nothing used: off
        step { [self] done in
            _ = app?.history.indexSnapshotNow(profileID: profile().id)
            AskAIAutomatic.refresh(app, profileID: profile().id, force: true, done: done)
        }
        run { [self] in
            let id = profile().id
            check(app?.settings.values.askAI.choice(for: id) == .automatic && c.commandBarAskAI == nil,
                  "\(tag): Automatic by default, off for a profile that uses no chat site")
        }
        openBar()
        typeText(prompt)
        run { [self] in
            check(bar?.query == prompt, "\(tag): “\(prompt)” typed (field “\(bar?.query ?? "-")”)")
            check(askIndex() == nil, "\(tag): Automatic and no chat site used: no Ask row (\(rows()))")
            c.closeCommandBar()

            // MARK: 2. Automatic picks Claude from history
            let id = profile().id
            app?.history.recordVisit(profileID: id, url: "https://claude.ai/new", title: "Claude")
            // Two pages that match the prompt, so history rows follow the Ask row.
            app?.history.recordVisit(profileID: id, url: base() + "/r/trams", title: "Why Lisbon trams have bells")
            app?.history.recordVisit(profileID: id, url: base() + "/r/bells", title: "Lisbon trams and their bells")
        }
        step { [self] done in
            _ = app?.history.indexSnapshotNow(profileID: profile().id)
            AskAIAutomatic.refresh(app, profileID: profile().id, force: true, done: done)
        }
        run { [self] in
            check(c.commandBarAskAI == .claude, "\(tag): a recent claude.ai visit makes Automatic pick Claude (\(c.commandBarAskAI?.name ?? "none"))")
        }
        wait(0.5)
        openBar()
        typeText(prompt)
        waitFor(3) { askIndex() != nil && (bar?.suggestionRowCount ?? 0) > 0 }
        wait(0.4)   // late history rows
        run { [self] in
            let i = askIndex()
            let row = i.flatMap { bar?.results[$0] }
            note("\(tag): rows \(rows())")
            check(row?.title == "Ask Claude" && row?.subtitle == prompt && row?.opensInNewTab == true,
                  "\(tag): the prompt gets “Ask Claude” (\(rows()))")
            check(i == min(CommandBarView.askRowIndex, (bar?.results.count ?? 1) - 1) && (bar?.results.count ?? 0) > 2,
                  "\(tag): Ask Claude is third, under the search row, with rows after it (index \(i ?? -1))")
            if case .open(let url)? = row?.action {
                check(url.absoluteString == base() + "/claude/new?q=" + encoded, "\(tag): its address is the new chat with the prompt (\(url))")
            } else {
                check(false, "\(tag): the Ask row opens an address")
            }
            check(AskAIProvider.claude.url(for: prompt)?.absoluteString == "https://claude.ai/new?q=" + encoded,
                  "\(tag): the real address is claude.ai/new?q=…")
            check(bar?.selected == 0, "\(tag): the search row is selected first (\(bar?.selected ?? -1))")
        }
        down()
        down()
        run { [self] in
            check(bar?.selected == askIndex() && askIndex() != nil, "\(tag): ↓↓ selects Ask Claude (selected \(bar?.selected ?? -1), rows \(rows()))")
        }
        returnKey()
        waitFor(10) { shownURL().contains("/claude/new?q=") && self.c.engineTab(for: self.c.shownTabID ?? "")?.title == "Loop Claude" }
        run { [self] in
            let opened = newTabs()
            check(c.commandBar == nil, "\(tag): Return closed the bar")
            check(opened.count == 1 && opened.first?.profileID == profile().id && opened.first?.id == c.shownTabID,
                  "\(tag): Return opened one new tab in the same profile (\(opened.map(\.url)))")
            check(shownURL() == base() + "/claude/new?q=" + encoded, "\(tag): the new tab is Claude's new chat with the prompt (\(shownURL()))")
        }

        // MARK: 3. Not prompts
        for text in ["lisbon trams", "example.com docs", "!yt why do cats purr", "/new split"] {
            openBar()
            typeText(text)
            run { [self] in
                check(askIndex() == nil, "\(tag): “\(text)” isn't a prompt: no Ask row (\(rows()))")
            }
        }

        // MARK: 4. ChatGPT chosen
        run { [self] in
            app?.settings.values.askAI.set(.provider(.chatGPT), for: profile().id)
            check(c.commandBarAskAI == .chatGPT, "\(tag): ChatGPT chosen")
        }
        openBar()
        typeText("how do magnets work?")
        waitFor(3) { askIndex() != nil && (bar?.suggestionRowCount ?? 0) > 0 }
        run { [self] in
            check(askIndex().flatMap { bar?.results[$0].title } == "Ask ChatGPT", "\(tag): a question gets “Ask ChatGPT” (\(rows()))")
        }
        down()
        down()
        run { [self] in check(bar?.selected == askIndex() && askIndex() != nil, "\(tag): ↓↓ selects Ask ChatGPT (selected \(bar?.selected ?? -1))") }
        returnKey()
        waitFor(10) { shownURL().contains("/chatgpt/?q=") && self.c.engineTab(for: self.c.shownTabID ?? "")?.title == "Loop ChatGPT" }
        run { [self] in
            check(shownURL() == base() + "/chatgpt/?q=how%20do%20magnets%20work%3F",
                  "\(tag): Return opened ChatGPT's new chat with the question (\(shownURL()))")
        }

        // The picture, in a bar of its own: drawing it takes the field's focus, so no key may follow it (bangs).
        run { [self] in app?.settings.values.askAI.set(.provider(.claude), for: profile().id) }
        openBar()
        typeText(prompt)
        waitFor(3) { askIndex() != nil && (bar?.suggestionRowCount ?? 0) > 0 }
        wait(0.3)
        capture("askai-row-claude")

        // MARK: 5. Off
        run { [self] in app?.settings.values.askAI.set(.off, for: profile().id) }
        openBar()
        typeText(prompt)
        run { [self] in
            check(c.commandBarAskAI == nil && askIndex() == nil, "\(tag): Off: the prompt gets no Ask row (\(rows()))")
            c.closeCommandBar()
            app?.settings.values.askAI.set(.automatic, for: profile().id)
            app?.showSettings(page: .ai)
        }
        waitFor(3) { TestAnchors.frames["ai.askAI"] != nil }
        run { [self] in app?.settingsWindow?.model.reveal("Command Bar") }
        wait(0.8)
        run { [self] in
            check(TestAnchors.frames["ai.askAI"] != nil, "\(tag): Settings → AI has Ask AI")
            if let v = app?.settingsWindow?.window.contentView, let img = render(v), let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
                let file = "askai-settings-ai" + (webkit ? ".png" : "-chromium.png")
                try? data.write(to: dir.appendingPathComponent(file))
                note("wrote \(file)")
            }
            app?.settingsWindow?.window.close()
            AskAIRoute.testTemplates = [:]
            SearchEngineStandIn.origin = nil
            AskAIAutomatic.forget()
            server?.stop()
            note("\(tag): done")
        }
    }
}
#endif
