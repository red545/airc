// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script importsuggest` (cbfixes; audit C08, auditsync2 NEXT #8): search engines brought in from another browser
/// suggest from their own endpoint (Chromium's `suggest_url`), under the built-in engines' privacy rules; and Arc's
/// "New ChatGPT Message" stays reachable without costing the first key.
///   1. An imported default site with an endpoint: typing asks that endpoint (never the profile's engine) and its
///      suggestions are rows that search the site.
///   2. An imported site with an endpoint, as the search in progress ("lv" + Tab): its own endpoint is asked.
///   3. A site without one (Airc's seeded YouTube): nothing is asked, no suggestion rows.
///   4. Suggestions off (Settings › Privacy), then the profile's "Include search engine suggestions" off: nothing asked.
///   5. A private window never asks an imported site's endpoint (its bar has no source for a site default or scope).
///   6. ChatGPT chosen: "g" shows no "New ChatGPT Message"; "chat" does, and running it opens the bar asking ChatGPT.
/// The endpoints are made-up https addresses on example domains, which the loopback stand-in (`SearchEngineStandIn`)
/// answers, so nothing leaves the Mac. With AIRC_REAL_KEYS=1 every key is a real driver key (PID-targeted).
extension SnapshotRunner {
    func importedSuggestCheck() {
        let webkit = app?.engine is WebKitEngine
        let tag = webkit ? "importsuggest (WebKit)" : "importsuggest (Chromium)"
        let real = UIDriverClient.requested
        var server: LocalPageServer?
        var port: UInt16 = 0
        let lock = NSLock()
        var requests: [String] = []
        var bar: CommandBarView? { self.c.commandBar }
        let profile = { self.c.store.profile(ofSpace: self.c.currentSpaceID) }
        var savedSites: SiteSearchSettings?
        var savedSuggestions = true
        func rows() -> String { bar?.resultTitles.joined(separator: " | ") ?? "-" }
        /// The suggestion requests (not the bar's preconnect, a HEAD to the stand-in's root).
        func asked() -> [String] { lock.withLock { requests.filter { $0 != "/" } } }
        func clearAsked() { lock.withLock { requests = [] } }
        func url(of r: CommandResult?) -> String? {
            if case .open(let u)? = r?.action { return u.absoluteString }
            return nil
        }
        let defaultPath = "/suggest.example.com/ac?q="
        let videoPath = "/video.example.com/sugg?q="

        func openBar() {
            run { [self] in
                c.closeCommandBar()
                c.openCommandBar(mode: .newTab)
            }
            wait(0.3)
        }

        func typeText(_ text: String) {
            step { [self] done in
                guard real else {
                    for ch in text { bar?.type((bar?.query ?? "") + String(ch)) }
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

        func tabKey() {
            step { [self] done in
                if real {
                    UIDriverClient.press(["tab"], pid: getpid()) { ok, out in
                        if !ok { self.note("FAIL-ENV \(tag) [real keys] tab: \(out)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
                    }
                    return
                }
                NSApp.sendEvent(Self.keyEvent(.tab, window: c.window))
                NSApp.sendEvent(Self.keyEvent(.tab, window: c.window, type: .keyUp))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
            }
        }

        func waitFor(_ timeout: Double = 4, _ condition: @escaping () -> Bool) {
            step { [self] done in waitUntil(condition, timeout: timeout, then: done) }
        }

        if real { activateForRealInput() }
        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.handler = { _ in LocalPageServer.Page(body: "<!doctype html><title>importsuggest</title><p>page</p>") }
            // Every suggestion request: the site endpoints answer "… loop one/two/three", any engine "… engine".
            server?.requestHandler = { r in
                lock.withLock { requests.append(r.target) }
                guard let q = URLComponents(string: "http://x" + r.target)?.queryItems?.first(where: { $0.name == "q" || $0.name == "query" })?.value
                else { return nil }
                let site = r.target.hasPrefix(defaultPath) || r.target.hasPrefix(videoPath)
                let list = (site ? [q + " loop one", q + " loop two", q + " loop three"] : [q + " engine"]).map { "\"\($0)\"" }
                return LocalPageServer.Page(headers: ["Content-Type": "application/json"],
                                            body: "[\"\(q)\",[\(list.joined(separator: ","))]]", delay: 0.04)
            }
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            check(port != 0, "\(tag): loopback endpoints listen")
            SearchEngineStandIn.origin = "http://127.0.0.1:\(port)"
            savedSuggestions = app?.settings.values.suggestionsEnabled ?? true
            app?.settings.values.suggestionsEnabled = true
            if !real { Self.emulateKeyWindow(c) { [weak self] in self?.note($0) } }
            note("\(tag): real keys \(real), app active \(NSApp.isActive), key window \(c.window.isKeyWindow), load \(Self.loadAverage())")

            // The import's result for an Arc/Chrome/Brave profile (C08b), as SearchEngineImportAdapter plans it.
            guard var s = app?.settings.values.siteSearch else { return check(false, "\(tag): settings") }
            savedSites = s
            let pid = profile().id
            let outcome = s.apply(SearchEngineImport(
                defaultSearch: .site(.init(name: "Loop Find", keyword: "lf", template: "https://find.example.com/search?q=%s",
                                           suggest: "https://suggest.example.com/ac?q={searchTerms}")),
                shortcuts: [.init(name: "Loop Video", keyword: "lv", template: "https://video.example.com/results?q=%s",
                                  suggest: "https://video.example.com/sugg?q=%s")]), to: pid)
            app?.settings.values.siteSearch = s
            check(outcome.defaultSite?.suggestTemplate == "https://suggest.example.com/ac?q=%s",
                  "\(tag): the imported default keeps its suggestion endpoint (\(outcome.defaultSite?.suggestTemplate ?? "none"))")
            check(profile().defaultSearch.site?.name == "Loop Find", "\(tag): the imported site is the profile's default")
        }

        // MARK: 1. The default site's own endpoint
        run { clearAsked() }
        openBar()
        typeText("lisbon")
        waitFor { (bar?.suggestionRowCount ?? 0) > 0 }
        wait(0.2)
        run { [self] in
            let a = asked()
            let sugg = bar?.results.filter { $0.badge == "Search" && $0.subtitle.isEmpty } ?? []
            note("\(tag) default: rows \(rows()); asked \(a)")
            check(bar?.query == "lisbon", "\(tag) default: “lisbon” typed (field “\(bar?.query ?? "-")”)")
            check(a.contains(defaultPath + "lisbon"), "\(tag) default: its own endpoint was asked for “lisbon”")
            check(a.allSatisfy { $0.hasPrefix(defaultPath) }, "\(tag) default: nothing else was asked, the profile's engine included (\(a))")
            check(sugg.first?.title == "lisbon loop one", "\(tag) default: its suggestions are rows (\(sugg.map(\.title)))")
            check(url(of: sugg.first) == "https://find.example.com/search?q=lisbon+loop+one",
                  "\(tag) default: a suggestion row searches the site (\(url(of: sugg.first) ?? "none"))")
            check(bar?.results.first?.title == "lisbon" && url(of: bar?.results.first) == "https://find.example.com/search?q=lisbon",
                  "\(tag) default: the search row is first and searches the site")
        }

        // MARK: 2. An imported site, as the search in progress
        run { clearAsked() }
        openBar()
        typeText("lv")
        tabKey()
        waitFor(2) { bar?.scope?.site.name == "Loop Video" }
        typeText("cats")
        waitFor { (bar?.suggestionRowCount ?? 0) > 0 }
        wait(0.2)
        run { [self] in
            let a = asked()
            let sugg = bar?.results.filter { $0.badge == "Search" && $0.subtitle.isEmpty } ?? []
            note("\(tag) scope: rows \(rows()); asked \(a)")
            check(bar?.scope?.site.name == "Loop Video", "\(tag) scope: “lv” + Tab searches Loop Video (\(bar?.scope?.name ?? "none"))")
            check(a.contains(videoPath + "cats"), "\(tag) scope: the site's own endpoint was asked for “cats”")
            check(!a.contains { $0.hasPrefix(videoPath) && !$0.hasPrefix(videoPath + "c") },
                  "\(tag) scope: what was typed before Tab (“lv”) never went to the site")
            check(!a.contains { $0.hasPrefix(defaultPath + "c") }, "\(tag) scope: the default's endpoint wasn't asked for the site's query (\(a))")
            check(sugg.first?.title == "cats loop one" && url(of: sugg.first) == "https://video.example.com/results?q=cats+loop+one",
                  "\(tag) scope: its suggestions search the site (\(sugg.map(\.title)), \(url(of: sugg.first) ?? "none"))")
            check(bar?.results.first?.title == "cats" && url(of: bar?.results.first) == "https://video.example.com/results?q=cats",
                  "\(tag) scope: the site's search row is first")
        }

        // MARK: 3. A site without an endpoint
        run { clearAsked() }
        openBar()
        typeText("yt")
        tabKey()
        waitFor(2) { bar?.scope?.site.name == "YouTube" }
        typeText("cats")
        wait(0.5)
        run { [self] in
            check(bar?.scope?.site.name == "YouTube", "\(tag) seeded: “yt” + Tab searches YouTube")
            check(asked().allSatisfy { !$0.contains("cats") }, "\(tag) seeded: nothing was asked for the site's query (\(asked()))")
            check(bar?.suggestionRowCount == 0, "\(tag) seeded: no suggestion rows (\(rows()))")
        }

        // MARK: 4. Privacy switches
        run { [self] in
            clearAsked()
            app?.settings.values.suggestionsEnabled = false
        }
        openBar()
        typeText("porto")
        wait(0.5)
        run { [self] in
            check(asked().isEmpty && bar?.suggestionRowCount == 0, "\(tag) off: suggestions off asks nothing (\(asked()); \(rows()))")
            app?.settings.values.suggestionsEnabled = true
            try? c.store.updateProfile(profile().id) { $0.searchSuggestions = false }
            clearAsked()
        }
        openBar()
        typeText("faro")
        wait(0.5)
        run { [self] in
            check(asked().isEmpty && bar?.suggestionRowCount == 0,
                  "\(tag) profile off: the profile's “Include search engine suggestions” off asks nothing (\(asked()); \(rows()))")
            try? c.store.updateProfile(profile().id) { $0.searchSuggestions = nil }
            c.closeCommandBar()
        }

        // MARK: 5. Private windows
        var priv: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in priv = w; done() }
        }
        run { [self] in
            guard let w = priv else { return check(false, "\(tag) private: a private window opens") }
            let video = app?.settings.values.siteSearch.searches(for: profile().id).first { $0.keyword == "lv" }
            check(w.commandBarSuggestionSource(scope: nil) == nil, "\(tag) private: an imported default site gets no suggestions there")
            check(video != nil && w.commandBarSuggestionSource(scope: video) == nil, "\(tag) private: nor does an imported site's search")
            w.closeWindow()
            priv = nil
        }
        wait(0.5)

        // MARK: 6. "New ChatGPT Message" from the second letter
        run { [self] in
            app?.settings.values.askAI.set(.provider(.chatGPT), for: profile().id)
            check(c.commandBarAskAI == .chatGPT, "\(tag) chatgpt: ChatGPT chosen")
        }
        openBar()
        typeText("g")
        wait(0.3)
        run { [self] in
            check(bar?.query == "g", "\(tag) chatgpt: “g” typed")
            check(!(bar?.results.contains { $0.title == "New ChatGPT Message" } ?? true),
                  "\(tag) chatgpt: one letter doesn't offer New ChatGPT Message (\(rows()))")
        }
        typeText("pt")
        wait(0.3)
        run { [self] in
            let shown = bar?.results.contains { $0.title == "New ChatGPT Message" } ?? false
            note("\(tag) chatgpt: “gpt” rows \(rows())")
            check(shown || bar?.scope != nil || bar?.results.contains { $0.title.hasPrefix("Ask ChatGPT") } == true,
                  "\(tag) chatgpt: “gpt” reaches ChatGPT (the command, or Ask ChatGPT + Tab)")
        }
        openBar()
        typeText("new chat")
        wait(0.3)
        run { [self] in
            let row = bar?.results.first { $0.title == "New ChatGPT Message" }
            check(row != nil, "\(tag) chatgpt: “new chat” offers New ChatGPT Message (\(rows()))")
            if case .run(let go)? = row?.action { go() } else { check(false, "\(tag) chatgpt: the command runs") }
            c.closeCommandBar()
        }
        waitFor(2) { self.c.commandBar?.scope == .ask(.chatGPT) }
        run { [self] in
            check(bar?.scope == .ask(.chatGPT), "\(tag) chatgpt: New ChatGPT Message opens the bar asking ChatGPT")
            c.closeCommandBar()
            app?.settings.values.askAI.set(.automatic, for: profile().id)
            AskAIAutomatic.forget()
        }

        run { [self] in
            c.closeCommandBar()
            if let savedSites { app?.settings.values.siteSearch = savedSites }
            app?.settings.values.suggestionsEnabled = savedSuggestions
            SearchEngineStandIn.origin = nil
            SuggestionService.shared.clear(profileID: profile().id)
            server?.stop()
            note("\(tag): done")
        }
    }
}
#endif
