// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import Network
import WebKit

/// `--script peekrules` (both engines): PK-1 site identity and AT-1 rules for Peek, with real UI-driver clicks on page
/// links. Every host is served by one loopback fixture: Chromium maps them with
/// `--host-resolver-rules=MAP *.co.uk 127.0.0.1, MAP *.duckdns.org 127.0.0.1` (launch argument), WebKit through the test
/// profile's own proxy (`proxyConfigurations`, only for those two suffixes).
///   - a pinned tab on peek-a.co.uk: a link to news.peek-a.co.uk (same registrable domain under co.uk) navigates in
///     place; one to peek-b.co.uk opens Peek, the pinned page stays;
///   - inside that Peek, a link a rule ("peek-c.co.uk" → a second Space) matches goes to the rule's Space, Peek closes;
///   - a pinned link to peek-c.co.uk itself goes straight to the rule's Space, no Peek;
///   - a pinned tab on alice-peek.duckdns.org: www.alice-peek… stays in place, bob-peek… opens Peek (each tenant of a
///     private suffix is its own site, as github.io);
///   - a Today tab: a plain cross-site click navigates in place (Peek is for pinned tabs and Favorites); ⇧-click opens
///     Peek (WebKit names ⇧-click as Chromium does since peekrules).
/// Without AIRC_REAL_KEYS=1 in a dedicated session the click cases SKIP; the site table still runs.
extension SnapshotRunner {
    func peekRulesScenario() {
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ s: String) -> String { "peekrules \(engine): " + s }
        var server: PeekRulesServer?
        var port: UInt16 = 0
        var home = "", dest = "", tab = ""
        var originalRules: [LinkRule] = []
        var originalPeek = true
        func url(_ host: String, _ path: String) -> String { "http://\(host):\(port)\(path)" }
        func mainPage() -> EngineTab? { c.engineTab(for: tab) }
        func restore() {
            c.closePeek()
            app?.settings.values.linkRules = originalRules
            app?.settings.values.peekEnabled = originalPeek
            if let profile = c.profiles.engineProfile(for: c.store.selectedSpace.profileID) as? WebKitProfile {
                profile.dataStore.proxyConfigurations = []
            }
            server?.stop()
        }

        step { [self] done in
            originalRules = app?.settings.values.linkRules ?? []
            originalPeek = app?.settings.values.peekEnabled ?? true
            app?.settings.values.linkRules = []
            app?.settings.values.peekEnabled = true
            home = c.currentSpaceID
            dest = (try? c.store.createSpace(name: "Peek rules", icon: .emoji("🛬"), profileID: c.store.selectedSpace.profileID).id) ?? ""
            server = try? PeekRulesServer()
            guard let server else { check(false, label("fixture server starts")); return done() }
            server.start { value in
                port = value
                self.c.profiles.whenLoaded(self.c.store.selectedSpace.profileID, { loaded in
                    if let profile = loaded as? WebKitProfile, let p = NWEndpoint.Port(rawValue: value) {
                        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: p))
                        proxy.matchDomains = ["co.uk", "duckdns.org"]
                        proxy.allowFailover = false
                        profile.dataStore.proxyConfigurations = [proxy]
                    }
                    done()
                }, failed: { self.check(false, label("profile loads")); done() })
            }
        }

        // The app's own decision on the bundled list (the same call Peek makes), before any click.
        run { [self] in
            let pairs: [(String, String, Bool)] = [
                ("docs.google.com", "mail.google.com", false), ("foo.github.io", "bar.github.io", true),
                ("bbc.co.uk", "news.bbc.co.uk", false), ("a.co.uk", "b.co.uk", true), ("alice.blogspot.com", "bob.blogspot.com", true),
                ("127.0.0.1", "localhost", true), ("localhost", "localhost:8080", false), ("bücher.de", "www.xn--bcher-kva.de", false),
                ("example.com.", "www.example.com", false),
            ]
            let wrong = pairs.filter { a, b, cross in
                WindowController.crossSite(URL(string: "https://\(a)/"), URL(string: "http://\(b)/")!) != cross
            }
            check(!PublicSuffixList.shared.isEmpty && wrong.isEmpty,
                  label("the app's list (\(PublicSuffixList.shared.ruleCount) rules) decides cross-site as eTLD+1 "
                        + "(wrong: \(wrong.map { "\($0.0)→\($0.1)" }.joined(separator: ", ")))"))
        }

        /// Shows `tab` at `path` on `host`, pinned or not, freshly loaded (a token in the query), Peek closed.
        func load(_ host: String, pinned: Bool) {
            let token = UUID().uuidString.prefix(8)
            run { [self] in
                c.closePeek()
                c.switchToSpace(home, animated: false)
                if tab.isEmpty, let t = try? c.store.openTab(url: url(host, "/source"), inSpace: home, title: "peek source") { tab = t.id }
                let isPinned = c.store.tab(tab)?.itemID != nil
                if isPinned != pinned { try? c.store.togglePin(tab, inSpace: home) }
                c.reloadAll(animated: false)
                c.show(tab, focus: true)
                mainPage()?.load(URL(string: url(host, "/source?t=\(token)"))!)
            }
            step { [self] done in
                waitUntil({ mainPage()?.url?.query == "t=\(token)" && mainPage()?.isLoading == false }, timeout: 10) {
                    let ok = mainPage()?.url?.host == host && (self.c.store.tab(tab)?.itemID != nil) == pinned
                    self.check(ok, label("source page on \(host), \(pinned ? "pinned" : "a Today tab") (\(mainPage()?.url?.absoluteString ?? "none"))"))
                    done()
                }
            }
        }

        // Model routing in the running app, no clicks: the same request shape both engines send.
        load("peek-a.co.uk", pinned: true)
        run { [self] in
            guard let opener = mainPage() else { return check(false, label("a page for the routing model")) }
            func wants(_ to: String, _ disposition: String) -> Bool {
                c.wantsPeek(EngineLinkRequest(url: URL(string: to)!, source: "page", disposition: disposition,
                                              sourceBundleID: nil, userGesture: true, opener: opener))
            }
            check(!wants(url("news.peek-a.co.uk", "/same"), "current_tab") && wants(url("peek-b.co.uk", "/cross"), "current_tab")
                  && wants(url("news.peek-a.co.uk", "/same"), "window"),
                  label("pinned tab: same site in place, another site Peek, ⇧-click (\"window\") Peek on any site"))
        }

        guard UIDriverClient.requested else {
            run { [self] in
                skip(label("real link clicks need AIRC_REAL_KEYS=1 in a dedicated session with Airc in front"))
                restore()
            }
            return
        }

        /// The link's centre in `page()`'s view, in window points, at click time.
        func point(of id: String, in page: @escaping () -> EngineTab?, _ then: @escaping (NSPoint?) -> Void) {
            c.root.layoutSubtreeIfNeeded()
            guard let p = page() else { return then(nil) }
            let view = p.view
            p.evaluate("(function(){var e=document.getElementById('\(id)');if(!e)return null;var r=e.getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]})()") { v in
                guard let xy = (v as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), xy.count == 2 else { return then(nil) }
                then(view.convert(NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : Double(view.bounds.height) - xy[1]), to: nil))
            }
        }

        /// A real driver click (plain, or with `mods`) on link `id` of `page()`, then `expect` within 8 s.
        func click(_ what: String, _ id: String, in which: (() -> EngineTab?)? = nil, mods: String? = nil,
                   expect: @escaping () -> Bool, detail: @escaping () -> String) {
            let page: () -> EngineTab? = which ?? { mainPage() }
            wait(0.6)   // past the double-click interval of the previous click
            uiCase(window: { self.c.window }) {
                step { [self] done in
                    point(of: id, in: page) { p in
                        guard let p else { self.check(false, label("\(what): the link \(id) is on screen")); return done() }
                        self.uiAttempt?.point = p
                        guard NSApp.isActive, self.c.window.isKeyWindow, let primary = NSScreen.screens.first else {
                            self.check(false, label("\(what): the window is the active key window")); return done()
                        }
                        let after: (Bool, String) -> Void = { ok, out in
                            self.waitUntil(expect, timeout: 8) {
                                self.check(ok && expect(), label("\(what) (real \(mods.map { $0 + "-" } ?? "")click, driver \(ok ? "ok" : out); \(detail()))"))
                                done()
                            }
                        }
                        if let mods {
                            UIDriverClient.click(p, in: self.c.window, mods: mods, after)
                        } else {
                            // No --mods: the driver refuses an empty one.
                            let s = self.c.window.convertPoint(toScreen: p)
                            UIDriverClient.run(["--click", String(Double(s.x)), String(Double(primary.frame.maxY - s.y))], after)
                        }
                    }
                }
            }
        }
        func state() -> String {
            "page \(mainPage()?.url.map { ($0.host ?? "") + $0.path } ?? "-"), Peek \(c.peek?.page.url.map { ($0.host ?? "") + $0.path } ?? "none"), "
                + "Space \(c.currentSpaceID == dest ? "rule's" : c.currentSpaceID == home ? "home" : "other")"
        }
        let peekPage: () -> EngineTab? = { self.c.peek?.page }

        // 1. Same registrable domain under co.uk: in place.
        load("peek-a.co.uk", pinned: true)
        click("pinned peek-a.co.uk → news.peek-a.co.uk (same site) navigates in place", "same",
              expect: { mainPage()?.url?.host == "news.peek-a.co.uk" && mainPage()?.isLoading == false && self.c.peek == nil }, detail: state)
        // 2. Another site: Peek over the page, the pinned page stays.
        load("peek-a.co.uk", pinned: true)
        click("pinned peek-a.co.uk → peek-b.co.uk (another site) opens Peek", "cross",
              expect: { self.c.peek?.page.url?.host == "peek-b.co.uk" && self.c.peek?.page.isLoading == false
                        && mainPage()?.url?.host == "peek-a.co.uk" && self.c.currentSpaceID == home }, detail: state)
        capture("peekrules-peek")
        // 3. A rule, followed from inside Peek: the rule's Space, not Peek.
        run { [self] in app?.settings.values.linkRules = [LinkRule(pattern: "peek-c.co.uk", spaceID: dest)] }
        click("a link inside Peek a rule matches opens in the rule's Space, Peek closes", "rule", in: peekPage,
              expect: { self.c.currentSpaceID == dest && self.c.peek == nil
                        && self.c.store.todayTabs(ofSpace: dest).contains { $0.url.hasPrefix(url("peek-c.co.uk", "/ruled")) } }, detail: state)
        // 4. A rule on a pinned tab's cross-site link: straight to the Space, no Peek, the pinned page stays.
        run { [self] in
            if let t = c.store.todayTabs(ofSpace: dest).first(where: { $0.url.contains("peek-c.co.uk") }) { _ = try? c.store.closeTab(t.id) }
        }
        load("peek-a.co.uk", pinned: true)
        click("pinned peek-a.co.uk → peek-c.co.uk with a rule goes to the rule's Space, not Peek", "rule",
              expect: { self.c.currentSpaceID == dest && self.c.peek == nil
                        && self.c.store.todayTabs(ofSpace: dest).contains { $0.url.hasPrefix(url("peek-c.co.uk", "/ruled")) }
                        && mainPage()?.url?.host == "peek-a.co.uk" }, detail: state)
        // 5. Without the rule's Space the rule is passed over: Peek again.
        run { [self] in app?.settings.values.linkRules = [LinkRule(pattern: "peek-c.co.uk", spaceID: "gone-space")] }
        load("peek-a.co.uk", pinned: true)
        click("a rule whose Space is gone is passed over (Peek)", "rule",
              expect: { self.c.peek?.page.url?.host == "peek-c.co.uk" && self.c.currentSpaceID == home }, detail: state)
        run { [self] in app?.settings.values.linkRules = [] }
        // 6. A private suffix (duckdns.org, like github.io): tenants are separate sites, a tenant's own subdomain is not.
        load("alice-peek.duckdns.org", pinned: true)
        click("pinned alice.… → www.alice.… (same tenant) navigates in place", "tenant",
              expect: { mainPage()?.url?.host == "www.alice-peek.duckdns.org" && self.c.peek == nil }, detail: state)
        load("alice-peek.duckdns.org", pinned: true)
        click("pinned alice.… → bob.… (another tenant of the suffix) opens Peek", "neighbour",
              expect: { self.c.peek?.page.url?.host == "bob-peek.duckdns.org" && mainPage()?.url?.host == "alice-peek.duckdns.org" },
              detail: state)
        // 7. A Today tab: a plain cross-site click is an ordinary click; ⇧-click is Peek.
        load("peek-a.co.uk", pinned: false)
        click("Today tab peek-a.co.uk → peek-b.co.uk navigates in place (Peek is for pinned tabs)", "cross",
              expect: { mainPage()?.url?.host == "peek-b.co.uk" && self.c.peek == nil }, detail: state)
        load("peek-a.co.uk", pinned: false)
        click("Today tab ⇧-click opens Peek", "cross", mods: "shift",
              expect: { self.c.peek?.page.url?.host == "peek-b.co.uk" && mainPage()?.url?.host == "peek-a.co.uk" }, detail: state)
        run { restore() }
    }
}

/// Loopback HTTP fixture and CONNECT endpoint (WebKit's per-profile proxy). Serves every host itself; never forwards.
private final class PeekRulesServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "airc.peekrules.fixture")
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

    /// Big block links, built from the page's own port. Two text-free paths keep the targets apart.
    static func page(_ path: String) -> String {
        let style = "<style>body{font:18px -apple-system;margin:0}a{display:block;margin:24px;padding:22px;width:420px;background:#eef}</style>"
        func link(_ id: String, _ host: String, _ target: String) -> String {
            "<a id='\(id)' data-h='\(host)' data-p='\(target)'>\(id): \(host)</a>"
        }
        let script = "<script>for(const a of document.querySelectorAll('a'))a.href='http://'+a.dataset.h+':'+location.port+a.dataset.p</script>"
        switch path {
        case "/source":
            return "<title>peek source</title>" + style
                + link("same", "news.peek-a.co.uk", "/same") + link("cross", "peek-b.co.uk", "/cross")
                + link("rule", "peek-c.co.uk", "/ruled") + link("tenant", "www.alice-peek.duckdns.org", "/tenant")
                + link("neighbour", "bob-peek.duckdns.org", "/neighbour") + script
        case "/cross":
            return "<title>peek target</title>" + style + link("rule", "peek-c.co.uk", "/ruled") + script
        default:
            return "<title>target \(path)</title>" + style + "<p>\(path)</p>"
        }
    }

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
            let raw = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = URL(string: raw)?.path ?? raw
            let payload = Data(Self.page(path.isEmpty ? "/" : path).utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
