// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    /// `--script launchtimeline` (fastlaunch): a cold launch (fresh data folder) is interactive without waiting for
    /// content blocking, and the profile's first page is still protected. The runner starts as the window appears,
    /// before the profile is ready (AppDelegate.openWindow); every other check starts once all profiles are.
    func launchTimelineScenario() {
        step { [self] done in
            Task { @MainActor in
                await LaunchTimelineCheck(runner: self).run()
                done()
            }
        }
    }
}

@MainActor private final class LaunchTimelineCheck {
    let runner: SnapshotRunner
    init(runner: SnapshotRunner) { self.runner = runner }
    var c: WindowController { runner.c }
    var app: AppDelegate { runner.app! }
    var chromium: Bool { app.engine.name.lowercased().contains("chromium") }
    func check(_ ok: Bool, _ what: String) { runner.check(ok, "launchtimeline: " + what) }
    func evaluate(_ tab: EngineTab, _ script: String) async -> Any? {
        await withCheckedContinuation { r in tab.evaluate(script) { r.resume(returning: $0) } }
    }
    func wait(seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func run() async {
        let profileID = c.currentProfileID
        let name = app.store.profile(profileID)?.name ?? profileID
        let readyAtStart = app.profiles.isReady(profileID)
        runner.note("launchtimeline: engine \(app.engine.name); the profile was \(readyAtStart ? "" : "not ")ready when the window was up")
        // A cold launch compiles the default lists; the window must not have waited for that.
        check(!readyAtStart, "the window is up before its profile's blocking rules are ready (a cold launch)")

        // While any profile isn't ready, no page of it exists (nothing loads unprotected).
        var unprotected: [String] = []
        let watcher = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for w in self.app.controllers {
                    for tab in self.app.store.state.tabs.values where w.engineTab(for: tab.id) != nil {
                        if !self.app.profiles.isReady(tab.profileID) { unprotected.append(tab.url) }
                    }
                }
            }
        }

        // The fixture's rules go in before the profile's first page: the launch's gate waits for them too.
        let server = LocalPageServer(pages: [:])
        let port: UInt16 = await withCheckedContinuation { r in
            guard let server else { return r.resume(returning: 0) }
            server.start { r.resume(returning: $0 ?? 0) }
        }
        guard let server, port != 0 else { check(false, "loopback server listening"); watcher.invalidate(); return }
        var requested: Set<String> = []   // server queue only
        let lock = NSLock()
        server.handler = { path in
            lock.lock(); requested.insert(path); lock.unlock()
            switch path {
            case "/": return .init(body: """
                <!doctype html><meta charset='utf-8'><title>Launch fixture</title>
                <script src='http://127.0.0.1:\(port)/ads.js'></script>
                <p class='sponsor'>Sponsored placement</p>
                <script>document.documentElement.dataset.fixtureDone = window.adRan ? 'ad' : 'yes'</script>
                """)
            case "/ads.js": return .init(headers: ["Content-Type": "text/javascript"], body: "window.adRan=true;")
            default: return .init(status: "404 Not Found", body: "")
            }
        }
        var rulesIn = false
        app.blocking.installCheckRules(BlockingCheckFixtures.rules, profile: profileID, includeDefaults: true) { rulesIn = true }
        // The fixture tab is picked now, before the profile is ready: it waits, with a blank card, and shows then.
        guard let row = try? c.store.openTab(url: "http://localhost:\(port)/", inSpace: c.currentSpaceID, activate: true, title: "Launch fixture") else {
            check(false, "fixture tab created"); watcher.invalidate(); return
        }
        c.reloadAll(animated: false)
        c.show(row.id, focus: false)
        if !app.profiles.isReady(profileID) {
            check(c.engineTab(for: row.id) == nil, "the picked tab has no page before its profile is ready")
            check(c.waitingForProfile?.tabID == row.id, "the window keeps the picked tab until its profile is ready")
        }
        // A link from another app before the profile is ready (release025: 3.68 s with no window in the first 0.1.14):
        // its Little Airc window shows at once with its address and no page; the page comes with the rules.
        let linkURL = URL(string: "http://localhost:\(port)/?link")!
        let linkStart = Date()
        let littleBefore = app.littleArcs.count
        app.openFromOtherApp([linkURL], source: "launchtimeline")
        let littleShown = await wait(seconds: 2) { self.app.littleArcs.count > littleBefore && self.app.littleArcs.last?.window.isVisible == true }
        let linkMs = Date().timeIntervalSince(linkStart) * 1000
        check(littleShown && linkMs < 500, String(format: "a link opened before its profile is ready shows its Little Airc window at once (%.0f ms, under 500)", linkMs))
        let little = littleShown ? app.littleArcs.last : nil
        if let little, !app.profiles.isReady(profileID) {
            check(little.page == nil && little.waitingURL == linkURL, "the link's window shows its address and has no page before the rules are ready")
        }
        let shown = await wait(seconds: 60) { self.c.engineTab(for: row.id) != nil }
        check(shown, "the picked tab gets its page once the profile is ready")
        check(rulesIn, "the fixture rules were installed before the page was created")
        guard shown, let tab = c.engineTab(for: row.id) else { watcher.invalidate(); server.stop(); return }
        let loaded = await wait(seconds: 20) { await self.evaluate(tab, "document.documentElement.dataset.fixtureDone") as? String != nil && !tab.isLoading }
        let done = await evaluate(tab, "document.documentElement.dataset.fixtureDone") as? String
        check(loaded && done == "yes", "the profile's first page loads with its third-party ad script blocked (\(done ?? "not loaded"))")
        lock.lock(); let adRequested = requested.contains("/ads.js"); lock.unlock()
        check(!adRequested, "the blocked ad script never reached the network")
        // The site's own cosmetic rule (localhost##.sponsor): EasyList's loopback generichide exception keeps generic
        // ones off here, as parityp20c asserts.
        let hidden = await wait(seconds: 5) { await self.evaluate(tab, "getComputedStyle(document.querySelector('.sponsor')).display === 'none'") as? Bool == true }
        check(hidden, "the first page's site cosmetic rule applies")
        if let count = app.blocking.count(for: tab) { check(count >= 1, "the page counts its blocked request (\(count))") }
        if let little {
            let linked = await wait(seconds: 20) {
                guard let p = little.page, !p.isLoading else { return false }
                return await self.evaluate(p, "document.documentElement.dataset.fixtureDone") as? String == "yes"
            }
            check(linked, "the link's page loads once the rules are ready, its ad script blocked")
            lock.lock(); let adAfterLink = requested.contains("/ads.js"); lock.unlock()
            check(!adAfterLink, "no blocked request reached the network from the link's page either")
        }

        let allReady = await wait(seconds: 60) { self.app.allProfilesAreReady }
        check(allReady, "every profile is ready")
        watcher.invalidate()
        check(unprotected.isEmpty, "no page existed in a profile before its blocking rules were ready (\(Set(unprotected).sorted().prefix(3)))")

        // The timeline: the window before the profile's gate, and interactive within budget.
        let t = LaunchTimeline.self
        let window = t.first("window on screen"), interactive = t.first("interactive"), ready = t.first("profile ready \(name)")
        runner.note("launch timeline:\n" + t.text)
        if let window, let ready { check(window < ready, String(format: "window on screen (%.0f ms) before the profile is ready (%.0f ms)", window, ready)) }
        else { check(false, "the timeline has the window and the profile's ready mark") }
        let budget: Double = chromium ? 1000 : 500
        if let interactive, let main = t.first("main") {
            // What Airc's code takes: from main.swift on. Before it is the system's part (dyld, the signature check of
            // a freshly built bundle: seconds on a busy build Mac), reported, not asserted. A busy Mac can be slower
            // than the status page's budget; twice it means waiting crept back in.
            let own = interactive - main
            check(own <= budget * 2, String(format: "interactive %.0f ms after main (budget %.0f ms; fails above %.0f)", own, budget, budget * 2))
            runner.note(String(format: "launchtimeline: interactive %.0f ms after process start (%.0f ms before main, %.0f ms after it), %@ the %.0f ms budget",
                               interactive, main, own, interactive <= budget ? "within" : "OVER", budget))
        } else { check(false, "the timeline has the main and interactive marks") }
        server.stop()
    }
}
#endif
