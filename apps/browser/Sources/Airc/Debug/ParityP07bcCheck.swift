// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script parityp07bc` (P07b + P07c, docs/qa/parity-audit.md A07 and A08, docs/user/command-bar.md), both engines,
/// against a loopback fake search site. Nothing leaves the machine: the chat site is pointed at a loopback page
/// (`AskAIRoute.testTemplates`), the profile's default search is a loopback site search (P07d), and Apple Intelligence
/// is a test override with a fake model.
///   1. Ask AI is off by default: "gpt" offers nothing and Tab accepts the completion as before.
///   2. ChatGPT chosen for the profile (kept across a settings reload): "gpt" shows "Ask ChatGPT · Press Tab"; Tab starts
///      it (pill, "Ask ChatGPT…"); Return opens the encoded question in a new tab of the same profile, even from ⌘L;
///      the real address would be chatgpt.com/?q=…; a typed question offers "Ask ChatGPT"; "New ChatGPT Message"; a
///      private window follows the profile; Off ends it.
///   3. Without Apple Intelligence: no Instant Links hint, the switch stays off, ⇧↵ is a normal search.
///   4. With it (fake): the hint row with ⇧↩; ⇧↵ finds the first organic result (ads, the site's own links and
///      javascript:/data:/file: links left out, no model asked), previews it, Return opens it; "top 3" previews three and
///      ⇧↵ opens three tabs; "top 9" stops at five; a page without marked results is the model's pick (titles and hosts
///      only); a model that declines, and a page that's too slow, fall back to a normal search; Esc cancels and nothing
///      opens; a private window has no Instant Links.
///   5. Settings → Site Search's Ask AI and Settings → AI's Instant Links, drawn to PNGs.
extension SnapshotRunner {
    func parityP07bcScenario() {
        let webkit = app?.engine is WebKitEngine
        let tag = webkit ? "parityp07bc (WebKit)" : "parityp07bc (Chromium)"
        var server: LocalPageServer?
        var port: UInt16 = 0
        let lock = NSLock()
        var requests: [String] = []
        var siteIDs: [String: String] = [:]
        var startTab = ""
        var tabsBefore = Set<String>()
        var bar: CommandBarView? { self.c.commandBar }
        let model = P07cFakeModel()
        let profile = { self.c.store.profile(ofSpace: self.c.currentSpaceID) }
        func base() -> String { "http://127.0.0.1:\(port)" }
        func requested(_ p: String) -> Bool { lock.withLock { requests.contains(p) } }
        func shownURL() -> String { c.engineTab(for: c.shownTabID ?? "")?.url?.absoluteString ?? "" }
        func newTabs() -> [LiveTab] { c.store.state.tabs.values.filter { !tabsBefore.contains($0.id) } }

        // MARK: Helpers

        func openBar(_ mode: CommandBarMode = .newTab) {
            run { [self] in
                c.closeCommandBar()
                if !startTab.isEmpty { c.show(startTab, focus: false) }
                tabsBefore = Set(c.store.state.tabs.keys)
                c.openCommandBar(mode: mode)
                bar?.keyLog = []
            }
            wait(0.2)
        }

        func typeText(_ text: String) {
            step { [self] done in
                bar?.type(text)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: done)
            }
        }

        /// A key through the app's own event path, then the window's (as parityp07's keys); ⇧↵ is the key monitor's,
        /// handed to the bar directly if the monitor didn't see it (a window that isn't key).
        func key(_ name: String, code: UInt16, chars: String, mods: NSEvent.ModifierFlags = [], evidence: String) {
            step { [self] done in
                let w: NSWindow = c.window
                let before = bar?.keyLog.count ?? 0
                func event(_ type: NSEvent.EventType) -> NSEvent {
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: w.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                }
                func arrived() -> Bool {
                    guard let log = self.c.commandBar?.keyLog else { return true }   // the key closed the bar
                    return log.dropFirst(before).contains(evidence)
                }
                NSApp.sendEvent(event(.keyDown))
                var path = "app"
                if !arrived() {
                    if mods == .shift, let b = bar { _ = b.handleSuggestionKey(event(.keyDown)); path = "direct" } else { w.sendEvent(event(.keyDown)); path = "window" }
                }
                NSApp.sendEvent(event(.keyUp))
                waitUntil({ arrived() }, timeout: 0.6) {
                    if !arrived() { self.note("\(tag): \(name) not delivered (\(self.inputBlocked ?? "no reason seen"))") }
                    if path != "app" { self.note("\(tag): \(name) handed over by the \(path) path (window key: \(w.isKeyWindow))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done)
                }
            }
        }
        func tab() { key("Tab", code: 48, chars: "\t", evidence: "insertTab:") }
        func returnKey() { key("Return", code: 36, chars: "\r", evidence: "insertNewline:") }
        func shiftReturn() { key("⇧↵", code: 36, chars: "\r", mods: .shift, evidence: "shiftReturn") }
        func esc() { key("Esc", code: 53, chars: "\u{1b}", evidence: "cancelOperation:") }
        func waitFor(_ timeout: Double = 4, _ condition: @escaping () -> Bool) {
            step { [self] done in waitUntil(condition, timeout: timeout, then: done) }
        }
        func setDefault(_ name: String?) {
            run { [self] in app?.settings.values.siteSearch.setDefault(name.flatMap { siteIDs[$0] }, for: profile().id) }
        }
        func png(_ name: String, _ window: NSWindow?) {
            guard let v = window?.contentView else { return note("\(tag): no window for \(name)") }
            v.layoutSubtreeIfNeeded()
            if let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                let file = name + (webkit ? ".png" : "-chromium.png")
                try? data.write(to: dir.appendingPathComponent(file))
                note("wrote \(file)")
            }
        }

        // MARK: The loopback site

        step { [self] done in
            let results = """
                <!doctype html><meta charset="utf-8"><title>Loop Find results</title>
                <nav><a href="/">Loop Find home</a> <a href="/settings">Settings</a></nav>
                <div id="tads"><a href="/ad/tram"><h3>Sponsored tram tours</h3></a></div>
                <div><a href="javascript:alert(1)"><h3>Script result</h3></a></div>
                <div><a href="data:text/html,x"><h3>Data result</h3></a></div>
                <div><a href="file:///etc/hosts"><h3>File result</h3></a></div>
                <div><a href="/r/tram28"><h3>Tram 28 guide</h3></a> <a href="/r/tram28#map">Map</a></div>
                <div><a href="/r/tram15"><h3>Tram 15 guide</h3></a></div>
                <div><a href="/r/tram12"><h3>Tram 12 guide</h3></a></div>
                <div><a href="/r/tram18"><h3>Tram 18 guide</h3></a></div>
                <div><a href="/r/tram24"><h3>Tram 24 guide</h3></a></div>
                <div><a href="/r/tram25"><h3>Tram 25 guide</h3></a></div>
                <footer><a href="/about">About</a></footer>
                """
            let plain = """
                <!doctype html><meta charset="utf-8"><title>Loop Plain results</title>
                <p><a href="/">Home</a> <a href="/p/help">Help</a></p>
                <ul><li><a href="/r/tram28">Tram 28 guide</a></li><li><a href="/r/tram15">Tram 15 guide</a></li>
                <li><a href="javascript:void(0)">Script link</a></li></ul>
                """
            server = LocalPageServer(responses: [:])
            server?.handler = { path in
                lock.withLock { requests.append(path) }
                switch path {
                case "/find": return LocalPageServer.Page(body: results)
                case "/plain": return LocalPageServer.Page(body: plain)
                case "/slow": return LocalPageServer.Page(body: "<title>Loop Slow results</title><p>late</p>", delay: 6)
                case "/chat": return LocalPageServer.Page(body: "<!doctype html><title>Loop Chat</title><p>chat</p>")
                default:
                    let name = path.hasPrefix("/r/tram") ? "Tram \(path.dropFirst(7)) guide" : "P07bc page"
                    return LocalPageServer.Page(body: "<!doctype html><title>\(name)</title><p>\(name)</p>")
                }
            }
            server?.start { p in
                guard let p, let t = try? self.c.store.openTab(url: "http://127.0.0.1:\(p)/start", inSpace: self.c.currentSpaceID) else {
                    self.check(false, "\(tag): the loopback site opens"); return self.finish()
                }
                port = p
                startTab = t.id
                self.c.reloadAll(animated: false)
                self.c.show(t.id, focus: false)
                self.waitUntil({ self.c.engineTab(for: t.id)?.isLoading == false && self.c.engineTab(for: t.id)?.title == "P07bc page" }, timeout: 15) { done() }
            }
        }
        run { [self] in
            guard let settings = app?.settings else { return check(false, "\(tag): the app's settings") }
            for (name, kw, path) in [("Loop Find", "lfind", "find"), ("Loop Plain", "lplain", "plain"), ("Loop Slow", "lslow", "slow")] {
                if case .success(let s) = settings.values.siteSearch.add(name: name, keyword: kw, template: base() + "/\(path)?q=%s", to: profile().id) {
                    siteIDs[name] = s.id
                }
            }
            check(siteIDs.count == 3, "\(tag): three loopback site searches")
            settings.values.siteSearch.setDefault(siteIDs["Loop Find"], for: profile().id)
            AskAIRoute.testTemplates = [.chatGPT: base() + "/chat?q=%s"]
            var o = InstantLinksResolver.Options()
            o.fetchTimeout = 2.5
            o.modelTimeout = 2
            InstantLinksFeature.testOptions = o
            InstantLinksFeature.testModel = model
            MainActor.assumeIsolated { AIFeatures.shared.testOverride = (.notEnabled, nil) }
        }

        // MARK: 1. Ask AI off by default

        openBar()
        typeText("gpt")
        run { [self] in
            check(app?.settings.values.askAI.choice(for: profile().id) == .automatic && c.commandBarAskAI == nil,
                  "\(tag): Ask AI is Automatic by default, and off for a profile that uses no chat site (askai)")
            check(bar?.askCandidate == nil && !(bar?.resultTitles.contains { $0.hasPrefix("Ask ChatGPT") } ?? true),
                  "\(tag): off, \"gpt\" offers no Ask ChatGPT row (\(bar?.resultTitles.joined(separator: " | ") ?? "-"))")
            check(!c.commandActions().contains { $0.title == "New ChatGPT Message" }, "\(tag): off, no New ChatGPT Message command")
        }
        tab()
        run { [self] in
            check(bar?.scope == nil, "\(tag): off, Tab after \"gpt\" starts nothing (field: \(bar?.fieldText ?? "-"))")
        }

        // MARK: 2. ChatGPT for this profile

        run { [self] in
            app?.settings.values.askAI.set(.chatGPT, for: profile().id)
            check(AppSettings(directory: AppPaths.dataDirectory).values.askAI.provider(for: profile().id) == .chatGPT,
                  "\(tag): ChatGPT chosen for the profile, kept across a settings reload")
            check(c.commandActions().contains { $0.title == "New ChatGPT Message" }, "\(tag): Arc's New ChatGPT Message is in the Command Bar")
        }
        openBar(.editURL)
        typeText("gpt")
        run { [self] in
            let row = bar?.results.first { $0.startsScope == .ask(.chatGPT) }
            check(bar?.askCandidate == .chatGPT && row?.title == "Ask ChatGPT" && row?.subtitle == "Press Tab",
                  "\(tag): \"gpt\" shows Ask ChatGPT · Press Tab (\(bar?.resultTitles.joined(separator: " | ") ?? "-"))")
        }
        tab()
        run { [self] in
            check(bar?.placeholderShown == true && bar?.placeholderText == "Ask ChatGPT…" && bar?.fieldText == "",
                  "\(tag): the empty field shows “Ask ChatGPT…” (\(bar?.placeholderShown == true ? "shown" : "hidden"))")
            png("parityp07bc-ask-placeholder", c.window)
        }
        typeText("what is a monad? c++ & 50%")
        run { [self] in check(bar?.placeholderShown == false, "\(tag): typing hides the placeholder") }
        run { [self] in
            let r = bar?.results.first
            var url = ""
            if case .open(let u)? = r?.action { url = u.absoluteString }
            check(bar?.scope == .ask(.chatGPT) && bar?.placeholderText == "Ask ChatGPT…" && (bar?.scopePillFrame.width ?? 0) > 20,
                  "\(tag): Tab starts it: the ChatGPT pill and \"Ask ChatGPT…\" (\(bar?.placeholderText ?? "-"))")
            check(url == base() + "/chat?q=what%20is%20a%20monad%3F%20c%2B%2B%20%26%2050%25" && r?.opensInNewTab == true && r?.badge == "Ask",
                  "\(tag): the row asks the encoded question in a new tab (\(url))")
            check(AskAIProvider.chatGPT.url(for: "what is a monad? c++ & 50%")?.absoluteString
                  == "https://chatgpt.com/?q=what%20is%20a%20monad%3F%20c%2B%2B%20%26%2050%25",
                  "\(tag): the real address is chatgpt.com/?q=… (not loaded)")
            lock.withLock { requests.removeAll() }
        }
        returnKey()
        waitFor(8) { requested("/chat") && newTabs().count == 1 }
        run { [self] in
            let opened = newTabs()
            check(opened.count == 1 && opened.first?.profileID == profile().id && opened.first?.id == c.shownTabID
                  && c.store.tab(startTab)?.url.hasSuffix("/start") == true,
                  "\(tag): Return opened one new tab in the same profile, the page it was asked from unchanged (\(opened.map(\.url)))")
            check(requested("/chat") && shownURL().contains("/chat?q=what%20is%20a%20monad"), "\(tag): the chat page got the question (\(shownURL()))")
        }
        openBar()
        typeText("why do lisbon trams have bells")
        run { [self] in
            let typed = "why do lisbon trams have bells"
            let results = bar?.results ?? []
            let ask = results.firstIndex { $0.title == "Ask ChatGPT" && $0.badge == "Ask" }
            let row = ask.flatMap { results[$0] }
            // askai: two arrows down (third), or right under the rows there are; agentpanel2's "Ask Airc to…" (normal
            // windows, key or not) right under it. This fixture has no history for the question, so: Search | Ask | Agent.
            let others = results.filter { $0.badge != "Ask" && $0.badge != "Agent" }.count
            let agent = results.firstIndex { $0.title == CommandBarView.agentRowTitle && $0.badge == "Agent" }
            check(row?.subtitle == typed && row?.opensInNewTab == true
                  && results.first?.badge == "Search" && results.first?.title == typed
                  && ask == min(CommandBarView.askRowIndex, others)
                  && agent != nil && agent == ask.map { $0 + 1 } && agent.map { results[$0].subtitle } == typed,
                  "\(tag): a typed question offers Ask ChatGPT under the search row, Ask Airc to… under it (askai) (\(bar?.resultTitles.joined(separator: " | ") ?? "-"))")
        }
        typeText("weather")
        run { [self] in
            check(!(bar?.results.contains { $0.title == "Ask ChatGPT" && $0.badge == "Ask" } ?? true), "\(tag): one word isn't a question: no Ask row")
            c.closeCommandBar()
            c.commandActions().first { $0.title == "New ChatGPT Message" }?.run()
        }
        wait(0.4)
        run { [self] in
            check(bar?.scope == .ask(.chatGPT), "\(tag): New ChatGPT Message opens the bar asking ChatGPT")
            app?.settings.values.askAI.set(nil, for: profile().id)
            bar?.update(allowCompletion: false)
            check(bar?.scope == nil, "\(tag): turned off, the bar stops asking")
            c.closeCommandBar()
            app?.settings.values.askAI.set(.chatGPT, for: profile().id)
        }
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { pw in
                self.check(pw?.commandBarAskAI == .chatGPT, "\(tag): a private window asks with its profile's choice")
                self.check(pw != nil && pw?.commandBarInstantLinks == nil, "\(tag): a private window has no Instant Links")
                pw?.closeWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
            }
        }

        // MARK: 3. Without Apple Intelligence

        run { [self] in
            if let s = app?.settings { InstantLinksFeature.set(true, settings: s) }
            check(app?.settings.values.instantLinks == false, "\(tag): without Apple Intelligence the Instant Links switch stays off")
        }
        openBar()
        typeText("tram guides")
        run { [self] in
            check(!(bar?.results.contains { $0.startsInstantLinks } ?? true), "\(tag): without it, no ⇧↵ hint (\(bar?.resultTitles.joined(separator: " | ") ?? "-"))")
            lock.withLock { requests.removeAll() }
        }
        shiftReturn()
        waitFor(8) { shownURL().hasSuffix("/find?q=tram+guides") }
        run { [self] in
            check(c.commandBar == nil && shownURL() == base() + "/find?q=tram+guides" && newTabs().count == 1,
                  "\(tag): without it, ⇧↵ is a normal search with the default (\(shownURL()))")
        }

        // MARK: 4. Instant Links (fake Apple Intelligence)

        run { [self] in
            MainActor.assumeIsolated { AIFeatures.shared.testOverride = (.available, nil) }
            if let s = app?.settings { InstantLinksFeature.set(true, settings: s) }
            check(app?.settings.values.instantLinks == true, "\(tag): with Apple Intelligence, Instant Links turns on")
        }
        openBar()
        typeText("tram guides")
        run { [self] in
            let i = bar?.results.firstIndex { $0.startsInstantLinks }
            let s = bar?.results.firstIndex { $0.badge == "Search" && $0.title == "tram guides" }
            check(i != nil && s != nil && i == s! + 1 && bar?.results[i!].shortcut == ["⇧", "↩"] && bar?.results[i!].title == "Open the Top Result",
                  "\(tag): the hint row under the search, with ⇧↩ (\(bar?.resultTitles.joined(separator: " | ") ?? "-"))")
            lock.withLock { requests.removeAll() }
        }
        shiftReturn()
        run { [self] in
            check(bar?.instantStateLabel == "finding" && bar?.results.first?.title == "Finding the best result…",
                  "\(tag): ⇧↵ shows Finding the best result… (\(bar?.instantStateLabel ?? "-"))")
        }
        waitFor(8) { bar?.instantStateLabel == "preview" }
        run { [self] in
            let plan = bar?.instantPreview
            let urls = plan?.links.map(\.url.absoluteString) ?? []
            check(urls == [base() + "/r/tram28"] && plan?.picker == .firstResults && model.asked.isEmpty,
                  "\(tag): the first organic result, ads, scripts, data and files left out, no model asked (\(urls))")
            check(plan?.searchURL.absoluteString == base() + "/find?q=tram+guides" && requested("/find"),
                  "\(tag): looked up with the profile's default search (\(plan?.searchURL.absoluteString ?? "-"))")
            check(bar?.results.first?.title == "Tram 28 guide" && bar?.results.last?.subtitle == "Search Loop Find instead",
                  "\(tag): the preview shows what will open and the normal search (\(bar?.resultTitles.joined(separator: " | ") ?? "-"))")
            check(newTabs().isEmpty, "\(tag): nothing opened before the preview is confirmed")
        }
        returnKey()
        waitFor(8) { self.c.engineTab(for: self.c.shownTabID ?? "")?.title == "Tram 28 guide" }
        run { [self] in
            check(newTabs().count == 1 && shownURL() == base() + "/r/tram28", "\(tag): Return opened it in a new tab (\(shownURL()))")
        }

        openBar()
        typeText("top 3 tram guides")
        run { [self] in check(bar?.results.contains { $0.title == "Open the Top 3 Results" } == true, "\(tag): \"top 3\": Open the Top 3 Results") }
        shiftReturn()
        waitFor(8) { bar?.instantStateLabel == "preview" }
        run { [self] in
            let urls = bar?.instantPreview?.links.map(\.url.absoluteString) ?? []
            check(urls == ["28", "15", "12"].map { base() + "/r/tram" + $0 } && bar?.results.first?.title == "Open 3 Results",
                  "\(tag): three previewed under Open 3 Results (\(bar?.resultTitles.joined(separator: " | ") ?? "-"))")
        }
        shiftReturn()
        waitFor(8) { newTabs().count == 3 && shownURL() == base() + "/r/tram28" }
        run { [self] in
            let urls = Set(newTabs().map(\.url))
            check(urls == Set(["28", "15", "12"].map { base() + "/r/tram" + $0 }) && shownURL() == base() + "/r/tram28",
                  "\(tag): ⇧↵ opened the three, the first shown (\(urls.sorted()))")
            for t in newTabs() { c.closeTab(t.id) }
        }

        openBar()
        typeText("top 9 tram guides")
        shiftReturn()
        waitFor(8) { bar?.instantStateLabel == "preview" }
        run { [self] in
            check(bar?.instantPreview?.links.count == InstantLinks.maxLinks && bar?.instantPreview?.requested == InstantLinks.maxLinks,
                  "\(tag): \"top 9\" stops at \(InstantLinks.maxLinks) (\(bar?.instantPreview?.links.count ?? 0))")
        }
        esc()
        run { [self] in
            check(c.commandBar != nil && bar?.instantStateLabel == "" && bar?.query == "top 9 tram guides" && newTabs().isEmpty,
                  "\(tag): Esc on the preview goes back to the typed rows, nothing opened")
        }

        // The model's pick (a page without marked results).
        setDefault("Loop Plain")
        run { model.answer = [4] }
        openBar()
        typeText("tram guide plain")
        shiftReturn()
        waitFor(8) { bar?.instantStateLabel == "preview" || self.c.commandBar == nil }
        run { [self] in
            let plan = bar?.instantPreview
            check(plan?.picker == .model && plan?.links.map(\.url.absoluteString) == [base() + "/r/tram15"],
                  "\(tag): without marked results the model picks (\(plan?.links.map(\.title) ?? []))")
            let asked = model.asked.last
            check(asked?.options.map(\.title) == ["Home", "Help", "Tram 28 guide", "Tram 15 guide"] && asked?.options.first?.host == "127.0.0.1",
                  "\(tag): the model saw titles and hosts only, no script link (\(asked?.options.map(\.title) ?? []))")
            c.closeCommandBar()
        }
        run { model.declines = true }
        openBar()
        typeText("tram guide plain")
        run { [self] in lock.withLock { requests.removeAll() } }
        shiftReturn()
        waitFor(8) { self.c.commandBar == nil }
        waitFor(8) { shownURL().contains("/plain?q=") }
        run { [self] in
            check(InstantLinksFeature.lastOutcome == .search(URL(string: base() + "/plain?q=tram+guide+plain"), .declined)
                  && shownURL() == base() + "/plain?q=tram+guide+plain",
                  "\(tag): a model that declines falls back to a normal search (\(shownURL()); outcome \(InstantLinksFeature.lastOutcome.map { "\($0)" } ?? "none"))")
            model.declines = false
        }

        // Too slow, then cancelled.
        setDefault("Loop Slow")
        openBar()
        typeText("slow trams")
        shiftReturn()
        waitFor(8) { self.c.commandBar == nil }
        waitFor(10) { shownURL().contains("/slow?q=") }
        run { [self] in
            check(InstantLinksFeature.lastOutcome == .search(URL(string: base() + "/slow?q=slow+trams"), .timeout)
                  && shownURL() == base() + "/slow?q=slow+trams",
                  "\(tag): a results page that's too slow falls back to a normal search (\(shownURL()); outcome \(InstantLinksFeature.lastOutcome.map { "\($0)" } ?? "none"))")
            InstantLinksFeature.lastOutcome = nil
        }
        openBar()
        typeText("cancelled trams")
        shiftReturn()
        run { [self] in check(bar?.instantStateLabel == "finding", "\(tag): finding (\(bar?.instantStateLabel ?? "-"))") }
        esc()
        run { [self] in
            check(c.commandBar != nil && bar?.instantStateLabel == "" && bar?.query == "cancelled trams"
                  && bar?.results.contains { $0.startsInstantLinks } == true,
                  "\(tag): Esc cancels the search; the typed rows come back (\(bar?.resultTitles.joined(separator: " | ") ?? "-"))")
        }
        wait(4)
        run { [self] in
            check(c.commandBar != nil && newTabs().isEmpty && InstantLinksFeature.lastOutcome == nil,
                  "\(tag): after the timeout nothing opened and nothing was searched")
            c.closeCommandBar()
        }

        // MARK: 5. Settings

        setDefault("Loop Find")
        run { [self] in app?.showSettings(page: .siteSearch) }
        waitFor(3) { TestAnchors.frames["sitesearch.askAI"] != nil }
        wait(0.4)
        run { [self] in
            check(TestAnchors.frames["sitesearch.askAI"] != nil, "\(tag): Settings → Site Search has Ask AI")
            png("parityp07bc-settings-ask", app?.settingsWindow?.window)
            app?.showSettings(page: .ai)
        }
        waitFor(3) { TestAnchors.frames["ai.instantLinks"] != nil }
        wait(0.4)
        run { [self] in
            check(TestAnchors.frames["ai.instantLinks"] != nil, "\(tag): Settings → AI has Instant Links")
            png("parityp07bc-settings-ai", app?.settingsWindow?.window)
            app?.settingsWindow?.window.close()
        }

        run { [self] in
            app?.settings.values.askAI.set(nil, for: profile().id)
            app?.settings.values.instantLinks = false
            app?.settings.values.siteSearch.setDefault(nil, for: profile().id)
            AskAIRoute.testTemplates = [:]
            InstantLinksFeature.testModel = nil
            InstantLinksFeature.testOptions = nil
            MainActor.assumeIsolated { AIFeatures.shared.testOverride = nil }
            server?.stop()
            note("\(tag): done")
        }
    }
}

/// The check's on-device model: answers `answer`, or declines.
final class P07cFakeModel: InstantLinksModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _answer: [Int] = []
    private var _declines = false
    private var _asked: [InstantLinksChoiceRequest] = []
    var answer: [Int] { get { lock.withLock { _answer } } set { lock.withLock { _answer = newValue } } }
    var declines: Bool { get { lock.withLock { _declines } } set { lock.withLock { _declines = newValue } } }
    var asked: [InstantLinksChoiceRequest] { lock.withLock { _asked } }

    func choose(_ request: InstantLinksChoiceRequest) async throws -> [Int] {
        lock.withLock { _asked.append(request) }
        if declines { throw AIRequestDeclined(.refusal) }
        return answer
    }
}
#endif
