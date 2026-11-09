// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
import Network
import WebKit

/// Both adapters, real co.uk PSL on hosts mapped to a loopback fixture. The context-menu callbacks
/// are invoked directly: posted right clicks cannot reliably traverse the engine's native menu.
extension SnapshotRunner {
    func routingCheck() {
        var server: RoutingPageServer?
        var port: UInt16 = 0
        var home = "", destination = "", source = ""
        var originalRules: [LinkRule] = []
        var originalRouter: ((EngineLinkRequest) -> Bool)?
        let page = { self.c.engineTab(for: source) }
        func url(_ host: String, _ path: String) -> URL { URL(string: "http://\(host):\(port)/\(path)")! }
        step { [self] done in
            originalRules = c.app?.settings.values.linkRules ?? []
            originalRouter = app?.engine.linkRouter
            app?.engine.linkRouter = { request in
                let peek = self.c.wantsPeek(request)
                let consumed = originalRouter?(request) ?? false
                self.note("routing: adapter request \(request.disposition), gesture \(request.userGesture), origin \(request.opener?.url?.host ?? "none"), Peek eligible \(peek), consumed \(consumed)")
                return consumed
            }
            c.app?.settings.values.linkRules = []
            c.app?.settings.values.peekEnabled = true
            home = c.currentSpaceID
            destination = (try? c.store.createSpace(name: "Routing destination", icon: .emoji("🧭"), profileID: c.store.selectedSpace.profileID).id) ?? ""
            server = try? RoutingPageServer()
            guard let server else { check(false, "routing: fixture server starts"); return done() }
            server.start { value in
                port = value
                self.c.profiles.whenLoaded(self.c.store.selectedSpace.profileID, { loaded in
                    if let profile = loaded as? WebKitProfile {
                        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
                        proxy.matchDomains = ["co.uk"]
                        proxy.allowFailover = false
                        profile.dataStore.proxyConfigurations = [proxy]
                    }
                    done()
                }, failed: { self.check(false, "routing: profile loads"); done() })
            }
        }
        func loadSource() {
            let token = UUID().uuidString
            run { [self] in
                c.closePeek()
                c.switchToSpace(home, animated: false)
                if source.isEmpty, let t = try? c.store.openTab(url: url("a.co.uk", "source").absoluteString, inSpace: home) {
                    source = t.id
                    try? c.store.togglePin(source, inSpace: home)
                }
                c.reloadAll(animated: false)
                c.show(source, focus: false)
                page()?.load(url("a.co.uk", "source?document=" + token))
            }
            step { [self] done in
                let deadline = Date().addingTimeInterval(10)
                func probe() {
                    guard let page = page() else { self.check(false, "routing: source page exists"); return done() }
                    page.evaluate("location.search.includes('\(token)') && document.readyState === 'complete' && !!document.getElementById('link')") { value in
                        if value as? Bool == true {
                            self.check(true, "routing: fresh source document loads on a.co.uk")
                            done()
                        } else if Date() >= deadline {
                            self.check(false, "routing: fresh source document loads on a.co.uk (\(page.url?.absoluteString ?? "none"))")
                            done()
                        } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: probe) }
                    }
                }
                probe()
            }
        }
        loadSource()
        step { [self] done in
            guard let p = page() else { return done() }
            check(!WindowController.crossSite(p.url, url("www.a.co.uk", "same")), "routing: same registrable site under multi-label suffix")
            check(WindowController.crossSite(p.url, url("b.co.uk", "cross")), "routing: different registrable sites under multi-label suffix")
            done()
        }
        // Targets are constructed at execution time, after the ephemeral port is known.
        step { [self] done in
            guard let p = page() else { return done() }
            p.evaluate("document.getElementById('link').href='\(url("www.a.co.uk", "same").absoluteString)';document.getElementById('link').click()") { _ in done() }
        }
        step { [self] done in
            waitUntil({ page()?.url?.path == "/same" }, timeout: 8) {
                self.check(page()?.url?.path == "/same" && self.c.peek == nil, "routing: same-site pinned link stays in place")
                done()
            }
        }
        loadSource()
        // The closures defer constructing URLs until the server has its port.
        func crossClick() {
            step { [self] done in
                guard let p = page() else { return done() }
                c.root.layoutSubtreeIfNeeded()
                // Focus the page's renderer, never activate the application/window. A first synthetic
                // mouse press on an unfocused renderer can otherwise be consumed without following the link.
                p.focus()
                #if canImport(AircCore)
                if let engine = app?.engine as? ChromiumEngine, p is ChromiumTab {
                    engine.devToolsCall("Runtime.evaluate", params: [
                        "expression": "new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))))",
                        "awaitPromise": true, "returnByValue": true
                    ], in: p) { reply, error in
                        self.check(error == nil && (reply?["result"] as? [String: Any])?["value"] as? Bool == true,
                                   "routing: renderer presents the link before trusted input")
                        done()
                    }
                    return
                }
                #endif
                done()
            }
            step { [self] done in
                guard let p = page() else { return done() }
                #if canImport(AircCore)
                if let engine = app?.engine as? ChromiumEngine, p is ChromiumTab {
                    p.evaluate("document.getElementById('link').href='\(url("b.co.uk", "cross").absoluteString)';var r=document.getElementById('link').getBoundingClientRect();[r.x+r.width/2,r.y+r.height/2]") { v in
                        guard let xy = v as? [Double], xy.count == 2 else { self.check(false, "routing: link bounds"); return done() }
                        var args: [String: Any] = ["x": xy[0], "y": xy[1], "button": "left", "clickCount": 1, "type": "mousePressed"]
                        engine.devToolsCall("Input.dispatchMouseEvent", params: args, in: p) { _, _ in
                            args["type"] = "mouseReleased"
                            engine.devToolsCall("Input.dispatchMouseEvent", params: args, in: p) { _, _ in done() }
                        }
                    }
                    return
                }
                #endif
                p.evaluate("document.getElementById('link').href='\(url("b.co.uk", "cross").absoluteString)';document.getElementById('link').click()") { _ in done() }
            }
        }
        crossClick()
        step { [self] done in
            waitUntil({ self.c.peek?.page.url?.path == "/cross" }, timeout: 8) {
                check(c.peek != nil && page()?.url?.path == "/source", "routing: no rule sends cross-site pinned link to Peek and keeps opener (peek \(c.peek != nil), opener \(page()?.url?.path ?? "none"), pinned \(c.store.tab(source)?.itemID != nil))")
                done()
            }
        }
        capture("routing-peek")
        loadSource()
        run { [self] in c.app?.settings.values.linkRules = [LinkRule(pattern: "b.co.uk", spaceID: destination)] }
        crossClick()
        step { [self] done in
            waitUntil({ self.c.currentSpaceID == destination }, timeout: 8) {
                check(c.currentSpaceID == destination && c.peek == nil && c.store.todayTabs(ofSpace: destination).contains { $0.url == url("b.co.uk", "cross").absoluteString }, "routing: explicit rule beats Peek and opens Today in destination")
                done()
            }
        }
        loadSource()
        run { [self] in
            #if canImport(AircCore)
            if let p = page() as? ChromiumTab {
                let target = url("b.co.uk", "menu").absoluteString
                let entries = p.tab(p.core, spacesForContextMenuLink: target)
                check(entries.compactMap { $0["id"] as? String } == c.windowSpaces.map(\.id), "routing: adapter supplies this window's ordered Spaces")
                check(entries.contains { ($0["title"] as? String) == "🧭 Routing destination" }, "routing: Space emoji accompanies its title")
                p.tab(p.core, openContextMenuLink: target, inSpace: destination)
                note("routing: context menu driven through ChromiumTab's native delegate entry points, not posted right-clicks")
            } else { skip("routing: WebKit has no context-menu customization path; see routing engine ask") }
            #else
            skip("routing: WebKit has no context-menu customization path; see routing engine ask")
            #endif
        }
        wait(0.6)
        run { [self] in
            #if canImport(AircCore)
            if page() is ChromiumTab {
                check(c.currentSpaceID == destination && c.store.todayTabs(ofSpace: destination).contains { $0.url == url("b.co.uk", "menu").absoluteString && $0.itemID == nil }, "routing: menu opens Today tab in chosen Space")
            }
            #endif
            c.app?.settings.values.linkRules = originalRules
            app?.engine.linkRouter = originalRouter
            if let profile = c.profiles.engineProfile(for: c.store.selectedSpace.profileID) as? WebKitProfile {
                profile.dataStore.proxyConfigurations = []
            }
            server?.stop()
        }
    }
}
/// HTTP fixture and CONNECT endpoint for WebKit's per-test-store proxy. Never forwards traffic;
/// every requested host is served locally. Chromium uses its host-resolver mapping to this same listener.
private final class RoutingPageServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "airc.routing.fixture")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }
    func start(_ ready: @escaping (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port {
                DispatchQueue.main.async { ready(port.rawValue) }
            }
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
                if complete || error != nil || bytes.count > 65536 { connection.cancel() }
                else { self.receive(connection, bytes) }
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
            let body = path == "/source" ? "<title>routing source</title><a id='link'>Follow link</a>" : "<title>routing target</title>"
            let payload = Data(body.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
