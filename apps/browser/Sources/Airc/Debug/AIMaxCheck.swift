// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script aimax` (docs/user/ai.md), both engines, on loopback pages with synthetic titles and a fake model
/// (`ScriptedTitleModel`), so it runs the same with or without Apple Intelligence: Tidy Titles off by default; with
/// Apple Intelligence missing, Settings → AI says so and nothing is tidied even with the setting on; turned on, long
/// titles of Today and pinned tabs get their short names (only the clean title and the host reach the model) and
/// short ones stay; the page's own title in the tab preview, or as the tooltip with previews off; a second tab of a
/// page named before is named from the cache, and the cache file holds names, never titles; a tab renamed by hand
/// keeps its name and isn't sent when its page's title changes; a private window's page is never sent; a stuck
/// model is cut off after its timeout, its late answer dropped, and the next page still gets named; off forgets
/// every name and records only `ai.tidy_titles` on or off. Last, with Apple Intelligence on, a timed run of the real
/// on-device model on synthetic titles (SKIP otherwise).
extension SnapshotRunner {
    /// Main actor: AIFeatures and AircKit's TidyTitles are; the steps' closures inherit it.
    @MainActor func aimaxScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        let ai = AIFeatures.shared
        let fake = ScriptedTitleModel([
            "Inbox - Gmail": "Gmail Inbox",
            "Pull requests - example-org/example-repo - GitHub": "GitHub Pull Requests",
            "Home - X": "X Home",
            "Q3 Planning - Docs - Example Drive": "Q3 Planning Docs",
            "Slow Page - Example Reports": "Slow Reports",
            "Release Notes - Example Blog": "Release Notes",
            "Q4 Planning - Docs - Example Drive": "Q4 Planning Docs",
            "Private - Mail": "Private Mail",
        ])
        fake.slow["Slow Page - Example Reports"] = 3
        let titles = [
            "gmail": "Inbox (3) - someone@example.com - Gmail",
            "pulls": "Pull requests · example-org/example-repo · GitHub",
            "x": "(12) Home / X",
            "plain": "Figma",
            "plan": "Q3 Planning – Docs – Example Drive",
            "slow": "Slow Page (2) – Example Reports",
            "after": "Release Notes (4) - Example Blog",
            "private": "Private (5) - secret@example.com - Mail",
        ]
        let names = ["gmail": "Gmail Inbox", "pulls": "GitHub Pull Requests", "x": "X Home", "plain": "Figma", "plan": "Q3 Planning Docs"]
        var server: LocalPageServer?
        var port: UInt16 = 0
        var tabs: [String: String] = [:]
        var planItem: String?
        var privateWindow: PrivateWindowController?
        var enabledAt: CFTimeInterval = 0
        let file = AppPaths.dataDirectory.appendingPathComponent("TidyTitles.json")
        func url(_ page: String) -> String { "http://127.0.0.1:\(port)/\(page).html" }
        func html(_ title: String, _ hex: String) -> String {
            "<!doctype html><meta charset=\"utf-8\"><title>\(title)</title><style>html,body{margin:0;height:100%;background:\(hex)}"
                + "h1{margin:0;padding:56px;font:600 40px -apple-system,sans-serif;color:#fff}</style><h1>\(title)</h1>"
        }
        func rows() -> [TabRowView] {
            guard let p = c.pageView(for: c.currentSpaceID) else { return [] }
            return p.rows.values.compactMap { $0 as? TabRowView }
        }
        func row(_ page: String) -> TabRowView? {
            if page == "plan", let id = planItem { return rows().first { $0.entry?.item?.id == id } }
            return tabs[page].flatMap { id in rows().first { $0.tabID == id && $0.entry?.item == nil } }
        }
        func shown(_ page: String) -> String { row(page)?.titleField.stringValue ?? "no row" }
        func asked() -> [TidyTitleRequest] { fake.asked }
        func loaded(_ pages: [String]) -> Bool {
            pages.allSatisfy { p in tabs[p].flatMap { c.engineTab(for: $0) }.map { $0.title == titles[p] && !$0.isLoading } ?? false }
        }

        // Fast and deterministic: short debounce and timeout, and no waiting for the person (the build Mac may be in
        // use; TidyTitlesTests cover the idle gate).
        run {
            var o = ai.tidy.options
            o.debounce = 0.3
            o.timeout = 1
            o.busyRetry = 0.2
            o.stallRetry = 0.5
            o.saveDelay = 0.5
            ai.tidy.options = o
            ai.isPersonActive = { false }
            ai.testOverride = (.notEnabled, nil)
        }
        step { [self] done in
            var pages: [String: String] = [:]
            for (i, p) in ["gmail", "pulls", "x", "plain", "plan", "slow", "after", "private"].enumerated() {
                pages["/\(p).html"] = html(titles[p]!, ["#c0392b", "#24292f", "#111111", "#a259ff", "#1a73e8", "#7f8c8d", "#16a085", "#3b3e4c"][i])
            }
            server = LocalPageServer(pages: pages)
            server?.start { p in
                guard let p else { self.check(false, "aimax (\(tag)): the loopback page server starts"); return self.finish() }
                port = p
                let store = self.c.store
                let space = self.c.currentSpaceID
                for page in ["plan", "plain", "x", "pulls", "gmail"] {
                    if let t = try? store.openTab(url: url(page), inSpace: space) { tabs[page] = t.id }
                }
                if let id = tabs["plan"] {
                    try? store.togglePin(id, inSpace: space)
                    planItem = store.tab(id)?.itemID
                }
                self.c.reloadAll(animated: false)
                if let id = tabs["gmail"] { self.c.show(id, focus: false) }
                done()
            }
        }
        step { [self] done in
            // Background tabs load when shown: show each once.
            let order = ["plan", "plain", "x", "pulls", "gmail"]
            @MainActor func next(_ i: Int) {
                guard i < order.count else { return done() }
                if let id = tabs[order[i]] { c.show(id, focus: false) }
                waitUntil({ loaded([order[i]]) }, timeout: 12) { next(i + 1) }
            }
            next(0)
        }
        run { [self] in
            check(loaded(["gmail", "pulls", "x", "plain", "plan"]) && planItem != nil,
                  "aimax (\(tag)): five loopback pages loaded, one pinned (\(tabs.keys.sorted().map { "\($0): \(c.engineTab(for: tabs[$0]!)?.title ?? "-")" }.joined(separator: "; ")))")
            // 1. Off by default.
            let originals = ["gmail", "pulls", "x", "plain", "plan"].allSatisfy { shown($0) == titles[$0] }
            check(app?.settings.values.tidyTitles == false && originals && asked().isEmpty,
                  "aimax (\(tag)): Tidy tab titles is off by default; rows show their pages' titles and nothing is asked")
            note("aimax (\(tag)): the system's availability: \(AppleIntelligence.availability.label) (first read "
                 + String(format: "%.2f ms", ai.availabilityReadSeconds * 1000) + ")")
        }

        // 2. Without Apple Intelligence: the switch can't turn it on, and a setting that is on tidies nothing.
        run { [self] in
            guard let settings = app?.settings else { return }
            ai.setTidyTitles(true, settings: settings)
            check(settings.values.tidyTitles == false && ai.lastToggleEvent == nil,
                  "aimax (\(tag)): without Apple Intelligence the switch stays off (\(ai.availability.label))")
            settings.values.tidyTitles = true   // as if turned on earlier, on a Mac where it ran
            app?.showSettings(page: .ai)
        }
        wait(1)
        run { [self] in
            let originals = ["gmail", "pulls", "x", "plan"].allSatisfy { shown($0) == titles[$0] }
            check(!ai.tidy.isActive && originals && asked().isEmpty && !ai.availability.isAvailable,
                  "aimax (\(tag)): with the setting on but Apple Intelligence off, no row is tidied and nothing is asked")
            captureAISettings("aimax-settings-unavailable.png")
            app?.settings.values.tidyTitles = false
        }

        // 3. Apple Intelligence available (the fake model): turned on in Settings → AI.
        run { [self] in
            guard let settings = app?.settings else { return }
            ai.testOverride = (.available, fake)
            enabledAt = CACurrentMediaTime()
            ai.setTidyTitles(true, settings: settings)
            let props = ai.lastToggleEvent?.properties
            check(settings.values.tidyTitles && ai.tidy.isActive
                  && props == ["feature": .string("ai.tidy_titles"), "variant": .string("on")],
                  "aimax (\(tag)): turned on, it records only feature.used \(props.map { "\($0)" } ?? "nothing")")
        }
        wait(0.6)
        run { [self] in captureAISettings("aimax-settings-on.png"); app?.settingsWindow?.window.orderOut(nil) }
        step { [self] done in
            waitUntil({ names.allSatisfy { shown($0.key) == $0.value } }, timeout: 8) {
                let took = CACurrentMediaTime() - enabledAt
                for (page, name) in names.sorted(by: { $0.key < $1.key }) {
                    self.check(shown(page) == name, "aimax (\(tag)): \"\(titles[page]!)\" shows as \"\(shown(page))\" (\(name))")
                }
                self.note("aimax (\(tag)): names \(String(format: "%.2f s", took)) after turning it on (debounce 0.3 s)")
                done()
            }
        }
        run { [self] in
            let a = asked()
            let want: Set<String> = ["Inbox - Gmail", "Pull requests - example-org/example-repo - GitHub", "Home - X",
                                     "Q3 Planning - Docs - Example Drive"]
            let leaks = a.filter { r in ["someone", "@", "127.0.0.1:", ".html", "(3)", "(12)"].contains { r.title.contains($0) || r.host.contains($0) } }
            check(Set(a.map(\.title)) == want && a.count == want.count && a.allSatisfy { $0.host == "127.0.0.1" } && leaks.isEmpty,
                  "aimax (\(tag)): the model got \(a.count) requests, each a clean title and the host only: "
                  + a.map { "\"\($0.title)\" @ \($0.host)" }.joined(separator: "; "))
        }
        capture("aimax-sidebar")

        // 4. The page's own title on hover: the preview card, or the tooltip with previews off.
        step { [self] done in
            guard let r = row("gmail") else { check(false, "aimax (\(tag)): the Gmail row"); return done() }
            check(r.toolTip == nil, "aimax (\(tag)): with tab previews on, no tooltip over the card")
            let p = r.convert(NSPoint(x: r.bounds.midX, y: r.bounds.midY), to: nil)
            if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                c.tabPreview.hoverBegan(r, event: e)
            }
            waitUntil({ self.c.tabPreview.isShowing }, timeout: 2) {
                if let card = self.c.tabPreview.card, self.c.tabPreview.isShowing {
                    self.check(card.titleText == titles["gmail"], "aimax (\(tag)): the tab preview shows the page's own title (\"\(card.titleText)\")")
                } else {
                    self.skip("aimax (\(tag)): the tab preview card didn't show (the window may not be drawn)")
                }
                if let e = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: self.c.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                    self.c.tabPreview.hoverEnded(r, event: e)
                }
                self.c.tabPreview.hide()
                done()
            }
        }
        run { [self] in
            app?.settings.values.tabPreviews = false
            AIFeatures.refreshAllRows()
            check(row("gmail")?.toolTip == titles["gmail"] && row("plan")?.toolTip == titles["plan"] && row("plain")?.toolTip == nil,
                  "aimax (\(tag)): with previews off, a tidied row's tooltip is its page's title (\(row("gmail")?.toolTip ?? "none"))")
            app?.settings.values.tabPreviews = true
            AIFeatures.refreshAllRows()
        }

        // 5. The cache: a second tab of the same page is named without asking, and the file keeps names, not titles.
        run { [self] in
            if let t = try? c.store.openTab(url: url("gmail"), inSpace: c.currentSpaceID) {
                tabs["gmail2"] = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: tabs["gmail2"] ?? "")?.title == titles["gmail"] }, timeout: 10) { done() } }
        wait(0.6)
        run { [self] in
            let before = asked().count
            check(shown("gmail2") == "Gmail Inbox" && before == 4, "aimax (\(tag)): a second Gmail tab is named from the cache (\(shown("gmail2")), \(before) requests)")
            ai.tidy.save()
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            check(text.contains("Gmail Inbox") && !text.contains("someone@example.com") && !text.contains("Inbox (3)"),
                  "aimax (\(tag)): TidyTitles.json in the data folder keeps names and fingerprints, never the titles (\(text.count) bytes)")
            if let id = tabs["gmail2"] { c.closeTab(id) }
        }

        // 6. A tab renamed by hand keeps its name, and its page's new title isn't sent.
        run { [self] in
            guard let item = planItem else { return }
            try? c.store.renameItem(item, to: "My Plan")
            c.reloadAll(animated: false)
            c.engineTab(for: tabs["plan"] ?? "")?.evaluate("document.title = '\(titles["plan"]!.replacingOccurrences(of: "Q3", with: "Q4"))'", completion: nil)
        }
        wait(1.5)
        run { [self] in
            let sent = asked().contains { $0.title.contains("Q4") }
            check(shown("plan") == "My Plan" && !sent && c.engineTab(for: tabs["plan"] ?? "")?.title.hasPrefix("Q4") == true,
                  "aimax (\(tag)): the pinned tab renamed \"My Plan\" keeps its name and its page's new title isn't sent (\(shown("plan")))")
        }

        // 7. A private window's page is never sent.
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                _ = w?.openPage(URL(string: url("private")))
                done()
            }
        }
        step { [self] done in waitUntil({ privateWindow?.shownPage?.title == titles["private"] }, timeout: 10) { done() } }
        wait(1.2)
        run { [self] in
            let sent = asked().contains { $0.title.contains("Private") || $0.title.contains("secret") }
            check(privateWindow?.shownPage?.title == titles["private"] && !sent && !ai.tidy.queue.contains(url("private")),
                  "aimax (\(tag)): a private window's \"\(titles["private"]!)\" never reaches the model (\(asked().count) requests in all)")
            privateWindow?.closeWindow()
        }

        // 8. A stuck model: cut off after the timeout, its late answer dropped, the next page still named.
        func open(_ page: String) {
            if let t = try? c.store.openTab(url: url(page), inSpace: c.currentSpaceID) { tabs[page] = t.id }
            c.reloadAll(animated: false)
            if let id = tabs[page] { c.show(id, focus: false) }
        }
        run { open("slow") }
        step { [self] done in waitUntil({ loaded(["slow"]) }, timeout: 12) { done() } }
        step { [self] done in
            let t0 = CACurrentMediaTime()
            waitUntil({ ai.tidy.stats.timeouts == 1 }, timeout: 4) {
                self.check(ai.tidy.stats.timeouts == 1 && shown("slow") == titles["slow"],
                           "aimax (\(tag)): a model that hangs is cut off after its 1 s timeout (\(ai.tidy.stats.timeouts) timeout, "
                           + String(format: "%.1f s", CACurrentMediaTime() - t0) + " after the page loaded); the row keeps \"\(shown("slow"))\"")
                open("after")
                done()
            }
        }
        step { [self] done in
            waitUntil({ shown("after") == "Release Notes" }, timeout: 8) {
                self.check(shown("after") == "Release Notes" && shown("slow") == titles["slow"],
                           "aimax (\(tag)): once it lets go the next page is named (\"\(shown("after"))\") and the late answer is dropped (\"\(shown("slow"))\")")
                done()
            }
        }

        // 9. Off: every row shows its page's title again, the names are forgotten, only "off" is recorded.
        run { [self] in
            guard let settings = app?.settings else { return }
            ai.setTidyTitles(false, settings: settings)
            let props = ai.lastToggleEvent?.properties
            let originals = ["gmail", "pulls", "x", "after"].allSatisfy { shown($0) == titles[$0] }
            check(!settings.values.tidyTitles && originals && props == ["feature": .string("ai.tidy_titles"), "variant": .string("off")],
                  "aimax (\(tag)): turned off, rows show their pages' titles and it records only \(props.map { "\($0)" } ?? "nothing")")
        }
        wait(0.8)
        run { [self] in
            let n = asked().count
            check(!FileManager.default.fileExists(atPath: file.path) && ai.tidy.cache.entries.isEmpty && ai.tidy.queue.isEmpty,
                  "aimax (\(tag)): off forgets every name (TidyTitles.json gone, \(n) requests in all)")
            ai.testOverride = nil
        }

        // 10. The real on-device model, when this Mac has Apple Intelligence on: synthetic titles, timed.
        step { [self] done in
            guard let model = AppleIntelligence.titleModel() else {
                skip("aimax (\(tag)): real on-device smoke run: this Mac's model is unavailable (\(AppleIntelligence.availability.label))")
                return done()
            }
            let samples = ["Inbox (3) - someone@example.com - Gmail", "(12) Home / X", "Pull requests · example-org/example-repo · GitHub",
                           "Q3 Planning Doc - Google Docs", "Weekly sync | Calendar | Example Corp - Outlook", "Example Project – Issues – Linear"]
            Task { @MainActor in
                var lines: [String] = []
                var times: [Double] = []
                var named = 0
                AppleIntelligence.prewarm()
                for t in samples {
                    let r = TidyTitlePrompt.request(title: t, url: "https://example.com/")
                    let start = CACurrentMediaTime()
                    let outcome = await TidyTitles.ask(model, r, timeout: 10)
                    let s = CACurrentMediaTime() - start
                    times.append(s)
                    switch outcome {
                    case .answer(let a):
                        let shown = TidyTitleRules.accept(a, title: t, host: r.host)
                        if shown != nil { named += 1 }
                        lines.append(String(format: "%.2f s", s) + " \"\(t)\" → \"\(a)\"" + (shown == nil ? " (dropped)" : ""))
                    case .declined: lines.append(String(format: "%.2f s", s) + " \"\(t)\" declined")
                    case .failed: lines.append(String(format: "%.2f s", s) + " \"\(t)\" failed")
                    case .timeout: lines.append("timeout \"\(t)\"")
                    }
                }
                lines.forEach { self.note("aimax (\(tag)): real model: " + $0) }
                let sorted = times.sorted()
                self.check(named * 2 >= samples.count && (sorted.last ?? 99) < 4,
                           "aimax (\(tag)): real on-device model named \(named)/\(samples.count) synthetic titles, median "
                           + String(format: "%.2f s, slowest %.2f s", sorted[sorted.count / 2], sorted.last ?? 0))
                done()
            }
        }
        run { server?.stop() }
    }

    /// `--script aimax-write`, then `aimax-read` on the same data folder: Tidy tab titles on at launch. The first run
    /// turns it on (the fake model) and names a pinned tab whose page never loads (a `.example` address). The second
    /// starts with the setting on, so a sidebar row makes AIFeatures while the window first draws (it must not reach
    /// itself from its own initialisation), shows the page's own title while Apple Intelligence is unavailable, and the
    /// name kept from the first run, without asking the model, once it is available.
    @MainActor func aimaxRelaunchScenario(write: Bool) {
        let tag = app?.engine.name.hasPrefix("Chromium") == true ? "chromium" : "webkit"
        let ai = AIFeatures.shared
        let title = "Inbox (3) - someone@example.com - Gmail"
        let saved = "https://mail.example/mail/u/0/#inbox"
        let fake = ScriptedTitleModel(write ? ["Inbox - Gmail": "Gmail Inbox"] : [:])
        let madeAtLaunch = AIFeatures.instantiated
        func shown() -> String {
            guard let p = c.pageView(for: c.currentSpaceID) else { return "no page" }
            return p.rows.values.compactMap { $0 as? TabRowView }.first { $0.entry?.item?.savedURL == saved }?.titleField.stringValue ?? "no row"
        }
        run {
            var o = ai.tidy.options
            o.debounce = 0.2
            ai.tidy.options = o
            ai.isPersonActive = { false }
        }
        if write {
            run { [self] in
                guard let settings = app?.settings else { return }
                ai.testOverride = (.available, fake)
                let space = c.currentSpaceID
                // Never shown, so never loaded: the row is the pinned item with its saved title.
                if let t = try? c.store.openTab(url: saved, inSpace: space, background: true, activate: false, title: title) {
                    try? c.store.togglePin(t.id, inSpace: space)
                }
                c.reloadAll(animated: false)
                ai.setTidyTitles(true, settings: settings)
            }
            step { [self] done in
                waitUntil({ shown() == "Gmail Inbox" }, timeout: 6) {
                    ai.tidy.save()
                    self.check(shown() == "Gmail Inbox" && fake.asked.count == 1 && self.app?.settings.values.tidyTitles == true,
                               "aimax relaunch (\(tag)): turned on, the pinned tab is named \"\(shown())\" and kept for the next launch")
                    done()
                }
            }
            return
        }
        run { [self] in
            check(madeAtLaunch && ai.tidy.isEnabled && app?.settings.values.tidyTitles == true,
                  "aimax relaunch (\(tag)): launched with Tidy tab titles on, the sidebar's rows made it as the window drew (made then: \(madeAtLaunch))")
            let real = AppleIntelligence.availability
            check(shown() == (real.isAvailable ? "Gmail Inbox" : title),
                  "aimax relaunch (\(tag)): at launch (the system's model: \(real.label)), the row shows \"\(shown())\"")
            ai.testOverride = (.available, fake)
        }
        wait(0.6)
        run { [self] in
            check(shown() == "Gmail Inbox" && fake.asked.isEmpty,
                  "aimax relaunch (\(tag)): with the model available, the name kept from the last launch shows without asking (\"\(shown())\", \(fake.asked.count) requests)")
            if let settings = app?.settings { ai.setTidyTitles(false, settings: settings) }
            ai.testOverride = nil
        }
    }

    private func captureAISettings(_ name: String) {
        guard let w = app?.settingsWindow?.window, let v = w.contentView else { return }
        v.layoutSubtreeIfNeeded()
        guard let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(name))
        note("wrote \(name)")
    }
}

/// The scripted run's model: answers from a table (by the title it is asked about), records each request, and can
/// hang on one page without stopping when cancelled, as a stuck model would.
final class ScriptedTitleModel: TidyTitleModel, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [TidyTitleRequest] = []
    let answers: [String: String]
    var slow: [String: TimeInterval] = [:]

    init(_ answers: [String: String]) { self.answers = answers }

    var asked: [TidyTitleRequest] { lock.withLock { requests } }

    func shortTitle(for request: TidyTitleRequest) async throws -> String {
        lock.withLock { requests.append(request) }
        if let s = slow[request.title] {
            let end = Date().addingTimeInterval(s)
            while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        return answers[request.title] ?? request.title
    }
}
#endif
