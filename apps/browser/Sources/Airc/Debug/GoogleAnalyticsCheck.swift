// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    /// `--script ganalytics`, both engines, real network, never signed in (no account, no email typed).
    /// A user couldn't open Google Analytics. Signed out, analytics.google.com, marketingplatform.google.com/home and
    /// tagmanager.google.com all end on Google's sign-in page; this asserts that page loads with its email field (no
    /// "browser not supported" / "may not be secure" page, no redirect loop) in the default profile and in a Space
    /// with its own profile, with the default lists on. It records the client-side hops, the user agent and Client
    /// Hints brands, and each page's blocked-request count. Tag Assistant (tagassistant.google.com, open without
    /// sign-in) checks airc-exceptions.txt: its own www.googletagmanager.com debug requests load there, while a
    /// loopback page's googletagmanager.com script stays blocked (the lists still block it everywhere else).
    func googleAnalyticsScenario() {
        step { [self] done in
            Task { @MainActor in
                await GoogleAnalyticsCheck(runner: self).run()
                done()
            }
        }
    }
}

@MainActor private final class GoogleAnalyticsCheck {
    let runner: SnapshotRunner
    var evidence: [[String: Any]] = []
    init(runner: SnapshotRunner) { self.runner = runner }
    var c: WindowController { runner.c }
    var app: AppDelegate { runner.app! }
    var center: BlockingCenter { app.blocking }
    var engineName: String { app.engine is WebKitEngine ? "webkit" : "chromium" }
    func check(_ ok: Bool, _ title: String) { runner.check(ok, "ganalytics \(engineName): " + title) }
    func note(_ text: String) { runner.note("ganalytics \(engineName): " + text) }
    func js(_ tab: EngineTab, _ script: String) async -> Any? {
        await withCheckedContinuation { resume in tab.evaluate(script) { resume.resume(returning: $0) } }
    }
    func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    static let targets = ["https://analytics.google.com/", "https://marketingplatform.google.com/home", "https://tagmanager.google.com/"]
    /// What Google shows a browser it won't serve (sign-in refusal, unsupported browser).
    static let refusals = ["may not be secure", "browser isn't supported", "browser is not supported", "unsupported browser",
                           "try using a different browser", "update your browser", "couldn't sign you in"]

    func open(_ url: String, space: String) -> EngineTab? {
        guard let row = try? c.store.openTab(url: url, inSpace: space) else { return nil }
        c.show(row.id, focus: false)
        return c.engineTab(for: row.id)
    }
    /// Polls the page until Google's sign-in identifier field is there and the load is done; records every URL seen.
    func signIn(_ tab: EngineTab, seconds: Double = 45) async -> (ok: Bool, hops: [String]) {
        var hops: [String] = []
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let href = await js(tab, "location.href") as? String, hops.last != href { hops.append(href) }
            let ready = await js(tab, """
                location.host === 'accounts.google.com' && document.readyState === 'complete' &&
                !!document.querySelector('#identifierId, input[type=email], input[name=identifier]')
                """) as? Bool == true
            if ready && !tab.isLoading { return (true, hops) }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return (false, hops)
    }
    func identity(_ tab: EngineTab) async -> [String: Any] {
        _ = await js(tab, """
            window.__aircUA = null;
            (navigator.userAgentData && navigator.userAgentData.getHighEntropyValues
              ? navigator.userAgentData.getHighEntropyValues(['fullVersionList', 'platform'])
              : Promise.resolve({})).then(v => { window.__aircUA = JSON.stringify({ua: navigator.userAgent,
                  webdriver: navigator.webdriver === true, brands: (navigator.userAgentData || {}).brands || null,
                  fullVersionList: v.fullVersionList || null, cookies: navigator.cookieEnabled}); },
                e => { window.__aircUA = JSON.stringify({ua: navigator.userAgent, error: String(e)}); });
            true
            """)
        for _ in 0..<30 {
            if let text = await js(tab, "window.__aircUA") as? String,
               let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return value }
            await sleep(0.1)
        }
        return [:]
    }

    func entries(profile: String, space: String, label: String) async {
        for target in Self.targets {
            guard let tab = open(target, space: space) else { check(false, "\(label) \(target): tab opened"); continue }
            let (ok, hops) = await signIn(tab)
            let href = await js(tab, "location.href") as? String ?? ""
            let text = (await js(tab, "document.body ? document.body.innerText : ''") as? String ?? "").lowercased()
            let refusal = Self.refusals.first { text.contains($0) }
            let host = URL(string: target)?.host ?? ""
            let continues = URLComponents(string: href)?.queryItems?.first { $0.name == "continue" }?.value ?? ""
            let who = await identity(tab)
            let blocked = center.count(for: tab) ?? -1
            check(ok, "\(label) \(target) ends on Google's sign-in page with its email field (\(hops.count) URLs: \(hops.map { String($0.prefix(70)) }))")
            check(refusal == nil, "\(label) \(target): no refusal page (\(refusal ?? "none"))")
            check(continues.contains(host), "\(label) \(target): sign-in continues to \(host) (\(continues.prefix(80)))")
            check(hops.count <= 8, "\(label) \(target): no redirect loop (\(hops.count) URLs)")
            check(who["webdriver"] as? Bool != true, "\(label) \(target): navigator.webdriver is not set")
            check(center.profileEnabled(for: tab), "\(label) \(target): the profile's protection is on")
            note("\(label) \(target): blocked requests \(blocked); UA \(who["ua"] ?? "?"); brands \(who["fullVersionList"] ?? who["brands"] ?? "none")")
            var diagnosis: [String: Any] = [:]
            if !ok {
                // What the error page says (Chromium names the net error), then the same URL with protection off and the
                // redirect's target directly: tells the blocker from the network.
                diagnosis["errorText"] = String(text.prefix(400))
                note("\(label) \(target): error page text: \(text.prefix(200).replacingOccurrences(of: "\n", with: " / "))")
                await withCheckedContinuation { resume in center.setCheckEnabled(false, profile: profile) { resume.resume() } }
                tab.load(URL(string: target)!)
                let off = await signIn(tab, seconds: 30)
                diagnosis["protectionOff"] = ["signInPage": off.ok, "hops": off.hops]
                note("\(label) \(target) with protection off: sign-in page \(off.ok) (\(off.hops.map { String($0.prefix(70)) }))")
                await withCheckedContinuation { resume in center.setCheckEnabled(true, profile: profile) { resume.resume() } }
                let direct = "https://analytics.google.com/analytics/web/"
                if target == "https://analytics.google.com/" {
                    tab.load(URL(string: direct)!)
                    let d = await signIn(tab, seconds: 30)
                    diagnosis["direct"] = ["url": direct, "signInPage": d.ok, "hops": d.hops]
                    note("\(label) \(direct) directly: sign-in page \(d.ok) (\(d.hops.map { String($0.prefix(70)) }))")
                }
            }
            evidence.append(["engine": engineName, "profile": label, "target": target, "final": href, "hops": hops, "signInPage": ok,
                             "refusal": refusal ?? NSNull(), "blockedRequests": blocked, "identity": who, "diagnosis": diagnosis,
                             "lists": Array(center.settings.configuration(profile).selectedLists).sorted()])
            tab.close()
        }
    }

    func tagAssistant(space: String) async {
        let url = "https://tagassistant.google.com/"
        guard let tab = open(url, space: space) else { check(false, "Tag Assistant tab opened"); return }
        var loaded = false
        for _ in 0..<200 {
            if !tab.isLoading, await js(tab, "location.host === 'tagassistant.google.com' && document.readyState === 'complete'") as? Bool == true { loaded = true; break }
            await sleep(0.2)
        }
        await sleep(4)   // its debug API calls run after load
        let resources = await js(tab, "JSON.stringify(performance.getEntriesByType('resource').map(e => e.name).filter(n => n.includes('googletagmanager.com')))") as? String ?? "[]"
        let blocked = center.count(for: tab) ?? -1
        check(loaded, "Tag Assistant loads signed out")
        check(blocked == 0, "Tag Assistant: none of its requests blocked (\(blocked); airc-exceptions.txt lets its googletagmanager.com calls through) \(resources.prefix(300))")
        evidence.append(["engine": engineName, "target": url, "blockedRequests": blocked, "googletagmanagerResources": resources])
        tab.close()
    }

    /// The lists still block googletagmanager.com on any other site: a loopback page's tag script.
    func elsewhere(space: String) async {
        let page = "<title>ganalytics control</title><script src='https://www.googletagmanager.com/gtm.js?id=GTM-AIRCTEST' onload='document.title=\"loaded\"' onerror='document.title=\"blocked\"'></script>"
        guard let server = LocalPageServer(pages: ["/": page]) else { check(false, "control server"); return }
        defer { server.stop() }
        let port: UInt16? = await withCheckedContinuation { resume in server.start { resume.resume(returning: $0) } }
        guard let port, let tab = open("http://localhost:\(port)/", space: space) else { check(false, "control page opened"); return }
        var title = ""
        for _ in 0..<100 {
            title = await js(tab, "document.title") as? String ?? ""
            if title == "loaded" || title == "blocked" { break }
            await sleep(0.1)
        }
        let blocked = center.count(for: tab) ?? -1
        check(title == "blocked" && blocked >= 1, "another site's googletagmanager.com script stays blocked (\(title), \(blocked) blocked)")
        evidence.append(["engine": engineName, "target": "loopback control", "result": title, "blockedRequests": blocked])
        tab.close()
    }

    func run() async {
        let home = c.currentSpaceID
        let profileID = c.store.profile(ofSpace: home).id
        await withCheckedContinuation { resume in center.setCheckEnabled(true, profile: profileID) { resume.resume() } }
        check(center.lists.aircExceptions.contains("tagassistant.google.com"), "Airc's exception list is bundled and read")
        await entries(profile: profileID, space: home, label: "default profile")
        await tagAssistant(space: home)
        await elsewhere(space: home)
        // A Space with its own profile: its own engine profile and blocking context.
        if let other = try? c.profiles.createProfile(name: "Analytics", emoji: "📈", color: nil),
           let space = try? c.store.createSpace(name: "Analytics", icon: .emoji("📈"), profileID: other.id) {
            let loaded: EngineProfile? = await withCheckedContinuation { resume in
                c.profiles.whenLoaded(other.id, { resume.resume(returning: $0) }, failed: { resume.resume(returning: nil) })
            }
            check(loaded != nil, "Space profile loaded")
            c.switchToSpace(space.id, animated: false)
            await withCheckedContinuation { resume in center.setCheckEnabled(true, profile: other.id) { resume.resume() } }
            await entries(profile: other.id, space: space.id, label: "Space profile")
            await tagAssistant(space: space.id)
        } else { check(false, "Space with its own profile created") }
        check(center.failures.isEmpty, "blocking configuration healthy (\(center.failures))")
        do {
            let bytes = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: runner.dir.appendingPathComponent("ganalytics-evidence.json"))
        } catch { check(false, "evidence written: \(error)") }
    }
}
#endif
