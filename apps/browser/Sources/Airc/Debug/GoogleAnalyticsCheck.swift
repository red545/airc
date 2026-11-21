// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
import Network
import WebKit

extension SnapshotRunner {
    /// `--script ganalytics`, both engines, real network, never signed in (no account, no email typed).
    /// A user couldn't open Google Analytics. Signed out, analytics.google.com, marketingplatform.google.com/home and
    /// tagmanager.google.com all end on Google's sign-in page; this asserts that page loads with its email field (no
    /// "browser not supported" / "may not be secure" page, no redirect loop) in the default profile and in a Space
    /// with its own profile, with the default lists on. It records the client-side hops, the user agent and Client
    /// Hints brands, and each page's blocked-request count. Tag Assistant (tagassistant.google.com, open without
    /// sign-in) checks airc-exceptions.txt: its own www.googletagmanager.com debug requests load there, while a
    /// loopback page's googletagmanager.com script stays blocked (the lists still block it everywhere else).
    /// Pages the person opens are blocked only by rules that name documents (`$document`): typed sentry.io and a
    /// made-up org on it load, and so do five hosts with a plain `||host^` rule, served by a loopback fixture.
    /// Chromium needs the mapping at launch, or that part SKIPs:
    ///   "--host-resolver-rules=MAP sentrymagic.com 127.0.0.1, MAP clarity.ms 127.0.0.1, MAP abilityscale.com 127.0.0.1,
    ///    MAP abjectattempt.com 127.0.0.1, MAP aboutcorgis.com 127.0.0.1, MAP allsportsflix.co.uk 127.0.0.1"
    ///   --disable-features=HttpsUpgrades
    /// allsportsflix.co.uk matches EasyList's `||allsportsflix.$document`: a rule that names documents still blocks it.
    /// WebKit uses the profile's own proxy for those hosts. A loopback page's Sentry browser SDK and ingest call (another
    /// site) stay blocked on both engines.
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
        // Before airc-exceptions.txt: 2 blocked (its gtag + debug/api/cookiespresent on www.googletagmanager.com), on both
        // engines. A Google log ping (play.google.com/log) can add one at times; that one stays blocked.
        check(blocked >= 0 && blocked <= 1, "Tag Assistant: its googletagmanager.com calls aren't blocked (\(blocked) blocked, was 2) \(resources.prefix(300))")
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

    /// Typed visits to sites whose host carries a `||host^$third-party` list rule: the page itself must load (before the
    /// engine's top-level first-party fix, Chromium showed "blocked by Airc" for them, as for analytics.google.com).
    static let listedHosts = ["https://hotjar.com/", "https://mixpanel.com/", "https://segment.com/",
                              "https://sentry.io/", "https://airc-made-up-org.sentry.io/"]
    func typedVisits(space: String) async {
        for target in Self.listedHosts {
            guard let tab = open(target, space: space) else { check(false, "typed \(target): tab opened"); continue }
            var href = "", text = "", ready = false
            for _ in 0..<150 {
                href = await js(tab, "location.href") as? String ?? ""
                if !tab.isLoading, await js(tab, "document.readyState") as? String == "complete", href.hasPrefix("http") || href.hasPrefix("chrome-error") {
                    ready = true; break
                }
                await sleep(0.2)
            }
            text = (await js(tab, "document.body ? document.body.innerText : ''") as? String ?? "").lowercased()
            // A blocked document ends on chrome-error:// (Chromium) or never loads; a site may redirect to another site
            // (hotjar.com → contentsquare.com, segment.com → twilio.com), which still proves its own document loaded.
            let landed = href.hasPrefix("https://") || href.hasPrefix("http://")
            check(ready && landed && !text.contains("blocked by airc"),
                  "typed \(target) loads, not Airc's block page (ends on \(href.prefix(80)))")
            evidence.append(["engine": engineName, "target": target, "kind": "typed visit", "final": href, "loaded": ready && landed,
                             "blockedPage": text.contains("blocked by airc"), "blockedRequests": center.count(for: tab) ?? -1])
            tab.close()
        }
    }

    /// The fix is for top-level documents only: a third-party tracker iframe, and a tracker script inside a third-party
    /// frame, stay blocked. Loopback page on localhost; its second frame is on 127.0.0.1 (another site).
    func trackerFrames(space: String) async {
        let page = """
            <title>ganalytics frames</title><body><script>
            window.__msgs = []; addEventListener('message', e => window.__msgs.push(String(e.data)));
            const a = document.createElement('iframe'); a.src = 'https://www.hotjar.com/'; document.body.appendChild(a);
            const b = document.createElement('iframe'); b.src = 'http://127.0.0.1:' + location.port + '/frame'; document.body.appendChild(b);
            </script></body>
            """
        let frame = """
            <title>third-party frame</title><script src='https://static.hotjar.com/c/hotjar-1.js?sv=6'
              onload="parent.postMessage('sub-loaded','*')" onerror="parent.postMessage('sub-blocked','*')"></script>
            <script>parent.postMessage('frame-up','*')</script>
            """
        guard let server = LocalPageServer(pages: ["/": page, "/frame": frame]) else { check(false, "frames server"); return }
        defer { server.stop() }
        let port: UInt16? = await withCheckedContinuation { resume in server.start { resume.resume(returning: $0) } }
        guard let port, let tab = open("http://localhost:\(port)/", space: space) else { check(false, "frames page opened"); return }
        var msgs: [String] = []
        for _ in 0..<100 {
            if let text = await js(tab, "JSON.stringify(window.__msgs || [])") as? String,
               let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String] { msgs = list }
            if msgs.contains("frame-up") && (msgs.contains("sub-blocked") || msgs.contains("sub-loaded")) { break }
            await sleep(0.1)
        }
        await sleep(1)
        let blocked = center.count(for: tab) ?? -1
        check(msgs.contains("frame-up") && msgs.contains("sub-blocked") && !msgs.contains("sub-loaded"),
              "a tracker script inside a third-party frame stays blocked (\(msgs))")
        check(blocked >= 2, "the third-party tracker iframe and the frame's tracker script are both blocked (\(blocked) blocked)")
        evidence.append(["engine": engineName, "target": "tracker frames", "messages": msgs, "blockedRequests": blocked])
        tab.close()
    }

    /// Hosts with a plain `||host^` rule in the default lists (no party or type option), none HSTS-preloaded.
    static let plainHosts = ["sentrymagic.com", "clarity.ms", "abilityscale.com", "abjectattempt.com", "aboutcorgis.com"]
    /// EasyList's `||allsportsflix.$document` (a rule that names documents) matches it.
    static let documentRuleHost = "allsportsflix.co.uk"
    static var fixtureHosts: [String] { plainHosts + [documentRuleHost] }
    func plainHostVisits(space: String) async {
        if !(app.engine is WebKitEngine) {
            let args = ProcessInfo.processInfo.arguments.joined(separator: " ")
            guard Self.fixtureHosts.allSatisfy({ args.contains("MAP \($0) 127.0.0.1") }), args.contains("HttpsUpgrades") else {
                runner.note("SKIP ganalytics chromium: plain-rule hosts need --host-resolver-rules for "
                    + Self.fixtureHosts.joined(separator: ", ") + " and --disable-features=HttpsUpgrades (see the scenario's comment)")
                return
            }
        }
        guard let server = try? PlainHostFixture() else { check(false, "plain-host fixture starts"); return }
        defer { server.stop() }
        let port: UInt16 = await withCheckedContinuation { resume in server.start { resume.resume(returning: $0) } }
        let profile = c.profiles.engineProfile(for: c.store.profile(ofSpace: space).id) as? WebKitProfile
        if let profile, let p = NWEndpoint.Port(rawValue: port) {
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: p))
            proxy.matchDomains = Self.fixtureHosts
            proxy.allowFailover = false
            profile.dataStore.proxyConfigurations = [proxy]
        }
        defer { profile?.dataStore.proxyConfigurations = [] }
        for host in Self.plainHosts {
            let target = "http://\(host):\(port)/"
            guard let tab = open(target, space: space) else { check(false, "typed \(host): tab opened"); continue }
            var title = "", href = ""
            for _ in 0..<100 {
                href = await js(tab, "location.href") as? String ?? ""
                title = await js(tab, "document.title") as? String ?? ""
                if !tab.isLoading, title.hasPrefix("plain fixture") || href.hasPrefix("chrome-error") { break }
                await sleep(0.1)
            }
            let text = (await js(tab, "document.body ? document.body.innerText : ''") as? String ?? "").lowercased()
            check(title == "plain fixture \(host)" && !text.contains("blocked by airc"),
                  "typed \(host) (a plain ||host^ rule) loads the page, not Airc's block page (\(title.isEmpty ? href : title))")
            evidence.append(["engine": engineName, "target": target, "kind": "plain-rule typed visit", "title": title, "final": href])
            tab.close()
        }
        // A rule that names documents still blocks the page itself: the fixture page never shows.
        let target = "http://\(Self.documentRuleHost):\(port)/"
        guard let tab = open(target, space: space) else { check(false, "typed \(Self.documentRuleHost): tab opened"); return }
        var title = "", href = ""
        for _ in 0..<60 {
            href = await js(tab, "location.href") as? String ?? ""
            title = await js(tab, "document.title") as? String ?? ""
            if title.hasPrefix("plain fixture") { break }
            await sleep(0.1)
        }
        let text = (await js(tab, "document.body ? document.body.innerText : ''") as? String ?? "").lowercased()
        check(!title.hasPrefix("plain fixture") && !tab.isLoading,
              "typed \(Self.documentRuleHost) (EasyList ||allsportsflix.$document) is still blocked (title \(title.isEmpty ? "none" : title), \(href.prefix(60)), blocked page text: \(text.contains("blocked by airc")))")
        evidence.append(["engine": engineName, "target": target, "kind": "$document rule", "title": title, "final": href,
                         "blockedPageText": text.contains("blocked by airc")])
        tab.close()
    }

    /// Sentry on another site: its browser SDK and an ingest call from a loopback page stay blocked.
    func sentryElsewhere(space: String) async {
        let page = """
            <title>ganalytics sentry</title><script>window.__s = {};</script>
            <script src='https://browser.sentry-cdn.com/8.0.0/bundle.min.js'
              onload="window.__s.sdk='loaded'" onerror="window.__s.sdk='blocked'"></script>
            <script>fetch('https://o1.ingest.sentry.io/api/1/envelope/?sentry_key=airc', {method: 'POST', mode: 'no-cors', body: '{}'})
              .then(() => window.__s.ingest = 'sent', () => window.__s.ingest = 'blocked');</script>
            """
        guard let server = LocalPageServer(pages: ["/": page]) else { check(false, "sentry fixture server"); return }
        defer { server.stop() }
        let port: UInt16? = await withCheckedContinuation { resume in server.start { resume.resume(returning: $0) } }
        guard let port, let tab = open("http://localhost:\(port)/", space: space) else { check(false, "sentry page opened"); return }
        var state: [String: String] = [:]
        for _ in 0..<100 {
            if let text = await js(tab, "JSON.stringify(window.__s || {})") as? String,
               let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] { state = value }
            if state["sdk"] != nil && state["ingest"] != nil { break }
            await sleep(0.1)
        }
        let blocked = center.count(for: tab) ?? -1
        check(state["sdk"] == "blocked", "another site's Sentry browser SDK stays blocked (\(state))")
        check(state["ingest"] == "blocked", "another site's Sentry ingest call stays blocked (\(state))")
        check(blocked >= 2, "both Sentry requests counted as blocked (\(blocked))")
        evidence.append(["engine": engineName, "target": "sentry on another site", "state": state, "blockedRequests": blocked])
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
        await typedVisits(space: home)
        await trackerFrames(space: home)
        await plainHostVisits(space: home)
        await sentryElsewhere(space: home)
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
/// One loopback fixture for every plain-rule host: answers CONNECT (WebKit's proxy) and serves each request a page
/// titled after its Host header.
private final class PlainHostFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "airc.ganalytics.fixture")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }
    func start(_ ready: @escaping (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port { DispatchQueue.main.async { ready(port.rawValue) } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, Data())
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, _ prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var bytes = prefix
            bytes.append(data ?? Data())
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || bytes.count > 65536 { connection.cancel() } else { self.receive(connection, bytes) }
                return
            }
            let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
            if head.hasPrefix("CONNECT ") {
                connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    self.receive(connection, Data(bytes[end.upperBound...]))
                })
                return
            }
            let lines = head.components(separatedBy: "\r\n")
            let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let hostLine = lines.first { $0.lowercased().hasPrefix("host:") } ?? ""
            let host = URL(string: target)?.host
                ?? hostLine.dropFirst(5).trimmingCharacters(in: .whitespaces).split(separator: ":").first.map(String.init) ?? ""
            let body = Data("<!doctype html><title>plain fixture \(host)</title><p>\(host)</p>".utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
