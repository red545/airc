// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
import WebKit

extension SnapshotRunner {
    /// --script devtoolscommands --remote-debugging-port=<scratch-only port>
    /// Chromium: map one.p20a.localhost, two.p20a.localhost and other.localhost
    /// to 127.0.0.1 with --host-resolver-rules. WebKit needs public loopback DNS.
    func devToolsCommandsScenario() {
        guard app?.engine is WebKitEngine else { developerCommandsChecks(); return }
        step { [self] done in
            var finished = false
            func resolved(_ failure: String?) {
                guard !finished else { return }; finished = true
                if let failure {
                    note("FAIL-ENV devtoolscommands: fixture DNS unavailable: \(failure); no fixture tabs or data checks started")
                } else {
                    developerCommandsChecks()
                }
                done()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                resolved("loopback hostname resolution exceeded 15 seconds")
            }
            var hosts = ["one.p20a.localtest.me", "two.p20a.localtest.me", "other.127.0.0.1.nip.io"]
            // Exercise the real failure path without changing the machine's resolver:
            // AIRC_DEVTOOLS_DNS_PROBE_HOST=missing.invalid.
            if let probe = ProcessInfo.processInfo.environment["AIRC_DEVTOOLS_DNS_PROBE_HOST"] {
                hosts.insert(probe, at: 0)
            }
            let names = hosts
            DispatchQueue.global(qos: .utility).async {
                var failure: String?
                for name in names {
                    let addresses = Host(name: name).addresses
                    guard addresses.contains("127.0.0.1"),
                          addresses.allSatisfy({ $0 == "127.0.0.1" || $0 == "::1" }) else {
                        let answer = addresses.isEmpty ? "no addresses (offline or resolver blocked the name)" : addresses.joined(separator: ", ")
                        failure = "\(name) resolved to \(answer), expected 127.0.0.1"
                        break
                    }
                }
                let reason = failure
                DispatchQueue.main.async { resolved(reason) }
            }
        }
    }

    private func developerCommandsChecks() {
        var server: LocalPageServer?, neighbor: LocalPageServer?
        var port: UInt16 = 0, otherPort: UInt16 = 0
        var id = "", otherID = "", siblingID = "", frontendID: String?, uiAllowed = false
        var consoleSeeded = false, webKitFrontend: ObjectIdentifier?
        var frontendState: String?, webKitState: String?
        var separateTab: EngineTab?, privateTab: EngineTab?, privateProfile: EngineProfile?
        let isWebKit = app?.engine is WebKitEngine
        // WebKit does not group unknown .localhost subdomains into website records,
        // and the transient fixture did not reuse HTTP responses. Use an owned UUID store
        // plus registered loopback DNS names for the site-scope cases.
        let targetHost = isWebKit ? "one.p20a.localtest.me" : "one.p20a.localhost"
        let siblingHost = isWebKit ? "two.p20a.localtest.me" : "two.p20a.localhost"
        let neighborHost = isWebKit ? "other.127.0.0.1.nip.io" : "other.localhost"
        let expectedDomain = isWebKit ? "localtest.me" : "p20a.localhost"
        let webKitStoreID = UUID()
        var fixtureTabs: [String: EngineTab] = [:], secureCacheTab: EngineTab?
        var fixtureProfile: WebKitProfile?
        let page = { fixtureTabs["target"] ?? self.c.engineTab(for: id) }
        let other = { fixtureTabs["neighbor"] ?? self.c.engineTab(for: otherID) }
        let sibling = { fixtureTabs["sibling"] ?? self.c.engineTab(for: siblingID) }
        var cacheBefore: [String: String] = [:], thirdPartySeeded = false
        func show(_ label: String) {
            if let tab = fixtureTabs[label] { self.c.engineWindow.activateTab(tab) }
            else { self.c.show(label == "target" ? id : label == "sibling" ? siblingID : otherID, focus: false) }
        }
        let fixture = "<title>Developer commands</title><body style='margin:0'><div id='inspect-me' style='width:150px;height:150px'>inspect me</div></body>"
        func evaluate(_ tab: EngineTab?, _ script: String, _ done: @escaping (Any?) -> Void) {
            guard let tab else { self.check(false, "devtoolscommands: fixture tab unavailable"); done(nil); return }
            tab.evaluate(script, completion: done)
        }
        func asyncEvaluate(_ tab: EngineTab?, _ body: String, _ done: @escaping (Any?) -> Void) {
            guard let tab else { self.check(false, "devtoolscommands: fixture tab unavailable"); done(nil); return }
            if let web = tab as? WebKitTab {
                web.webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                    switch result { case .success(let value): done(value); case .failure(let error):
                        self.check(false, "devtoolscommands: fixture JavaScript: \(error)"); done(nil) }
                }
                return
            }
            #if canImport(AircCore)
            if let engine = self.app?.engine as? ChromiumEngine {
                engine.devToolsCall("Runtime.evaluate", params: ["expression": "(async () => {" + body + "})()",
                    "awaitPromise": true, "returnByValue": true], in: tab) { result, error in
                    self.check(error == nil && result?["exceptionDetails"] == nil, "devtoolscommands: fixture JavaScript completed")
                    done((result?["result"] as? [String: Any])?["value"])
                }
                return
            }
            #endif
            self.check(false, "devtoolscommands: no asynchronous fixture evaluator"); done(nil)
        }
        step { [self] done in
            guard let primary = LocalPageServer(pages: ["/": fixture]),
                  let secondary = LocalPageServer(pages: ["/": fixture]) else {
                check(false, "devtoolscommands: fixture server unavailable"); done(); return
            }
            for service in [primary, secondary] {
                var requests: [String: Int] = [:] // used only on this server's serial queue
                service.handler = { path in
                    if path.hasPrefix("/http-cache-") {
                        requests[path, default: 0] += 1
                        return .init(headers: ["Cache-Control": "public, max-age=86400"], body: "response-\(requests[path]!)")
                    }
                    if path == "/thirdparty" || path == "/thirdparty-read" {
                        return .init(headers: path == "/thirdparty" ? ["Set-Cookie": "p20a_thirdparty=keep; SameSite=None; Secure; Partitioned; Path=/"] : [:],
                            body: "<script>parent.postMessage({p20aThirdParty:document.cookie.includes('p20a_thirdparty=keep')},'*')</script>")
                    }
                    return nil
                }
            }
            server = primary; neighbor = secondary
            primary.start { port = $0 ?? 0; secondary.start { otherPort = $0 ?? 0
                self.check(port != 0 && otherPort != 0, "devtoolscommands: both fixture servers started")
                done()
            } }
        }
        run { [self] in
            if isWebKit {
                note("devtoolscommands: owned WebKit store \(webKitStoreID.uuidString)")
                let profile = WebKitProfile(directory: "p20a-" + webKitStoreID.uuidString,
                                            dataStore: WKWebsiteDataStore(forIdentifier: webKitStoreID))
                fixtureProfile = profile
                for (label, host, fixturePort) in [("target", targetHost, port), ("sibling", siblingHost, port), ("neighbor", neighborHost, otherPort)] {
                    fixtureTabs[label] = c.engineWindow.openTab(url: URL(string: "http://\(host):\(fixturePort)/"), profile: profile, foreground: false)
                }
                return
            }
            if let t = try? c.store.openTab(url: "http://\(targetHost):\(port)/", inSpace: c.currentSpaceID) { id = t.id }
            if let t = try? c.store.openTab(url: "http://\(siblingHost):\(port)/", inSpace: c.currentSpaceID) { siblingID = t.id }
            if let t = try? c.store.openTab(url: "http://\(neighborHost):\(otherPort)/", inSpace: c.currentSpaceID) { otherID = t.id }
            c.reloadAll(animated: false)
        }
        for (label, tab) in [("target", page), ("sibling", sibling), ("neighbor", other)] {
            run { show(label) }
            step { [self] done in waitUntil({ tab()?.title == "Developer commands" }, timeout: 10) { done() } }
            step { [self] done in
                asyncEvaluate(tab(), """
                localStorage.setItem('p20a','\(label)'); sessionStorage.setItem('p20a','\(label)');
                document.cookie='p20a_\(label)=keep; Path=/';
                window.p20aDocumentMarker = 'original';
                const db = await new Promise((resolve,reject) => {
                  const r=indexedDB.open('p20a',1); r.onupgradeneeded=()=>r.result.createObjectStore('values');
                  r.onsuccess=()=>resolve(r.result); r.onerror=()=>reject(r.error);
                }); db.close();
                if ('caches' in window) { const cache = await caches.open('p20a'); await cache.put('/cache-entry',new Response('stored')); }
                return await (await fetch('/http-cache-\(label)')).text();
                """) { value in
                    cacheBefore[label] = value as? String
                    check(cacheBefore[label] != nil, "devtoolscommands: seeded \(label) storage, cookie and HTTP cache")
                    done()
                }
            }
            step { [self] done in asyncEvaluate(tab(), "return await (await fetch('/http-cache-\(label)')).text();") { value in
                check(value as? String == cacheBefore[label], "devtoolscommands: \(label) HTTP cache reused before clear"); done()
            } }
        }
        run { show("target") }
        step { done in evaluate(page(), """
            window.p20aThirdParty = null;
            addEventListener('message', e => { if(e.data?.p20aThirdParty !== undefined) window.p20aThirdParty=e.data.p20aThirdParty; });
            const f=document.createElement('iframe'); f.src='http://\(neighborHost):\(otherPort)/thirdparty'; document.body.append(f); true;
            """) { _ in done() } }
        wait(1)
        step { [self] done in evaluate(page(), "window.p20aThirdParty") { value in
            thirdPartySeeded = value as? Bool == true
            if !thirdPartySeeded { note("SKIP devtoolscommands: browser blocked third-party fixture cookie; first-party unrelated-site cookie is still checked") }
            done()
        } }
        run { [self] in
            let w = c.window
            uiAllowed = !Self.screenLocked && w.isOnActiveSpace && w.occlusionState.contains(.visible)
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
            if !uiAllowed {
                note("FAIL-ENV devtoolscommands: no UI commands run; pid=\(getpid()) window=\(w.windowNumber) activeSpace=\(w.isOnActiveSpace) occlusion=\(w.occlusionState.rawValue) frontPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) locked=\(Self.screenLocked)")
            }
        }
        for panel in [EngineDevToolsPanel.console, .network, .console] {
            step { [self] done in
                guard uiAllowed, let tab = page() else { done(); return }
                tab.showDevTools(panel: panel) { result in
                    if tab is WebKitTab, panel == .network {
                        if case .failure(.unavailable) = result { check(true, "devtoolscommands: WebKit Network limitation explicit") }
                        else { check(false, "devtoolscommands: WebKit must report unavailable Network selection") }
                    } else {
                        if case .success = result { check(true, "devtoolscommands: show \(panel.rawValue)") }
                        else { check(false, "devtoolscommands: show \(panel.rawValue): \(result)") }
                    }
                    if panel == .console, !consoleSeeded, case .success = result {
                        tab.evaluate("console.log('p20a-console-history'); true") { _ in consoleSeeded = true; done() }
                    } else { done() }
                }
            }
            wait(0.5)
            step { [self] done in
                guard uiAllowed else { done(); return }
                if let tab = page() as? WebKitTab {
                    guard let inspector = tab.webView.value(forKey: "_inspector") as? NSObject,
                          inspector.responds(to: NSSelectorFromString("inspectorWebView")),
                          let frontend = inspector.perform(NSSelectorFromString("inspectorWebView"))?.takeUnretainedValue() as? WKWebView else {
                        check(false, "devtoolscommands: Web Inspector frontend evidence unavailable"); done(); return
                    }
                    if let previous = webKitFrontend {
                        check(previous == ObjectIdentifier(frontend), "devtoolscommands: Web Inspector frontend survives Console/Network refusal/Console")
                    }
                    webKitFrontend = ObjectIdentifier(frontend)
                    frontend.evaluateJavaScript("""
                    (() => {
                      WI.consoleLogViewController.renderPendingMessages();
                      const messages = [];
                      function walk(root) { for (const e of root.querySelectorAll('*')) {
                        if (e.classList.contains('console-message')) messages.push(e.textContent);
                        if (e.shadowRoot) walk(e.shadowRoot);
                      }}
                      walk(document);
                      globalThis.p20aState ??= Math.random().toString(36);
                      return {history: messages.some(text => text.includes('p20a-console-history')), state: globalThis.p20aState};
                    })()
                    """) { value, error in
                        let fields = value as? [String: Any]
                        self.check(fields?["history"] as? Bool == true && error == nil, "devtoolscommands: Web Inspector Console history retained")
                        if let previous = webKitState {
                            self.check(fields?["state"] as? String == previous, "devtoolscommands: Web Inspector document state survives")
                        }
                        webKitState = fields?["state"] as? String
                        done()
                    }
                    return
                }
                developerFrontendRead("""
                (async () => {
                  const UI = await import('./ui/legacy/legacy.js');
                  globalThis.p20aState ??= Math.random().toString(36);
                  const text = [];
                  function walk(root) { for (const e of root.querySelectorAll('*')) {
                    if (e.classList.contains('console-message')) text.push(e.textContent);
                    if (e.shadowRoot) walk(e.shadowRoot);
                  }}
                  walk(document);
                  return {panel: UI.InspectorView.InspectorView.instance().tabbedPane.selectedTabId,
                          state: globalThis.p20aState, history: text.join(' ')};
                })()
                """) { target, value in
                    let fields = value as? [String: Any]
                    if let frontendID { check(target == frontendID, "devtoolscommands: frontend identity survives panel switch") }
                    else { frontendID = target }
                    if let previous = frontendState {
                        check(fields?["state"] as? String == previous, "devtoolscommands: frontend document state survives")
                    }
                    frontendState = fields?["state"] as? String
                    check(fields?["panel"] as? String == panel.rawValue, "devtoolscommands: selected \(panel.rawValue)")
                    if panel == .console {
                        check((fields?["history"] as? String)?.contains("p20a-console-history") == true,
                              "devtoolscommands: console history retained")
                    }
                    done()
                }
            }
        }
        step { [self] done in
            guard uiAllowed, let tab = page() else { done(); return }
            tab.inspectElement(at: CGPoint(x: 40, y: 40)) { result in
                if tab is WebKitTab {
                    if case .failure(.unavailable) = result { check(true, "devtoolscommands: WebKit point inspection limitation explicit") }
                    else { check(false, "devtoolscommands: WebKit point inspection must report unavailable") }
                } else if case .success = result { check(true, "devtoolscommands: point inspection dispatched") }
                else { check(false, "devtoolscommands: point inspection \(result)") }
                done()
            }
        }
        wait(0.5)
        step { [self] done in
            guard uiAllowed, !(page() is WebKitTab) else { done(); return }
            developerFrontendRead("""
            (async () => {
              const UI = await import('./ui/legacy/legacy.js');
              const SDK = await import('./core/sdk/sdk.js');
              return UI.Context.Context.instance().flavor(SDK.DOMModel.DOMNode)?.getAttribute('id');
            })()
            """) { _, value in check(value as? String == "inspect-me", "devtoolscommands: selected node under viewport point"); done() }
        }
        for cycle in 1...10 {
            run { if uiAllowed { page()?.closeDevTools() } }
            wait(0.3)
            step { [self] done in
                guard uiAllowed, let tab = page() else { done(); return }
                check(!tab.isDevToolsOpen, "devtoolscommands: cycle \(cycle) closes inspector")
                if tab is WebKitTab {
                    check(NSApp.windows.filter { $0.title.hasPrefix("Web Inspector") }.count <= 1,
                          "devtoolscommands: cycle \(cycle) does not accumulate Web Inspector windows")
                }
                #if canImport(AircCore)
                if let chromium = tab as? ChromiumTab {
                    check(chromium.toolsPanel == nil && chromium.core.devToolsView == nil,
                          "devtoolscommands: cycle \(cycle) releases docked view and native host")
                }
                #endif
                tab.showDevTools(panel: .console) { result in
                    if case .success = result { check(true, "devtoolscommands: cycle \(cycle) reopens") }
                    else { check(false, "devtoolscommands: cycle \(cycle): \(result)") }
                    done()
                }
            }
        }
        run { page()?.closeDevTools() }
        step { [self] done in
            guard uiAllowed, let tab = page(), !(tab is WebKitTab) else { done(); return }
            tab.showDevTools(panel: .console) { result in
                if case .failure = result { check(true, "devtoolscommands: close cancels a pending open") }
                else { check(false, "devtoolscommands: cancelled open must not succeed") }
                done()
            }
            tab.closeDevTools()
        }
        wait(0.5)
        run { [self] in
            if uiAllowed { check(page()?.isDevToolsOpen == false, "devtoolscommands: delayed callbacks do not reopen inspector") }
        }
        // Data-only checks work without drawing or taking focus. Use the same site
        // in a separate profile and in an off-the-record context.
        step { [self] done in
            app?.engine.loadProfile(directory: "p20a-separate-profile") { profile in
                if let profile { separateTab = self.c.engineWindow.openTab(url: URL(string: "http://\(targetHost):\(port)/"), profile: profile, foreground: false) }
                done()
            }
        }
        step { [self] done in waitUntil({ separateTab?.title == "Developer commands" }, timeout: 10) { done() } }
        step { done in
            guard let tab = separateTab else { done(); return }
            tab.evaluate("localStorage.setItem('p20a','separate-profile'); document.cookie='p20a_separate=keep; Path=/'; true") { _ in done() }
        }
        step { [self] done in
            guard let profile = page()?.profile else { done(); return }
            func opened(_ profile: EngineProfile?) {
                privateProfile = profile
                if let profile { privateTab = self.c.engineWindow.openTab(url: URL(string: "http://\(targetHost):\(port)/"), profile: profile, foreground: false) }
                done()
            }
            #if canImport(AircCore)
            if let chromium = app?.engine as? ChromiumEngine { chromium.offTheRecordProfile(for: profile, completion: opened); return }
            #endif
            if let webkit = app?.engine as? WebKitEngine { opened(webkit.makePrivateProfile()) } else { opened(nil) }
        }
        step { [self] done in waitUntil({ privateTab?.title == "Developer commands" }, timeout: 10) { done() } }
        step { [self] done in
            guard let tab = privateTab else { check(false, "devtoolscommands: private tab created"); done(); return }
            tab.evaluate("localStorage.getItem('p20a') === null") { value in
                self.check(value as? Bool == true, "devtoolscommands: private context cannot see persistent origin storage")
                tab.evaluate("localStorage.setItem('p20a','private'); document.cookie='p20a_private=keep; Path=/'; true") { _ in done() }
            }
        }
        step { [self] done in
            guard let tab = privateTab else { done(); return }
            tab.clearSiteDataAndReload { result in
                if case .failure(.unavailable) = result { check(true, "devtoolscommands: private tab clear refused explicitly") }
                else { check(false, "devtoolscommands: private tab clear must leave data untouched: \(result)") }
                done()
            }
        }
        step { [self] done in evaluate(page(), "localStorage.getItem('p20a') === 'target'") { value in
            check(value as? Bool == true, "devtoolscommands: private clear refusal preserves regular data"); done()
        } }
        step { [self] done in
            guard let tab = page() else { check(false, "devtoolscommands: target tab missing"); done(); return }
            tab.siteDataDomain { result in
                if case .success(let domain) = result { check(domain == expectedDomain, "devtoolscommands: scope resolves parent site including sibling subdomain: \(domain)") }
                else { check(false, "devtoolscommands: site scope unavailable: \(result)") }
                done()
            }
        }
        step { [self] done in
            guard let tab = page() else { done(); return }
            tab.clearSiteDataAndReload { result in
                if case .success = result { check(true, "devtoolscommands: site cookies, storage and caches clear completed") }
                else { check(false, "devtoolscommands: site clear: \(result)") }
                done()
            }
        }
        wait(1)
        for (label, tab) in [("target", page), ("sibling", sibling)] {
            step { [self] done in asyncEvaluate(tab(), """
                return {local: localStorage.getItem('p20a'), session: sessionStorage.getItem('p20a'),
                        cookie: document.cookie, databases: (await indexedDB.databases()).map(d=>d.name),
                        caches: 'caches' in window ? await caches.keys() : null, http: await (await fetch('/http-cache-\(label)')).text()};
                """) { value in
                    let fields = value as? [String: Any]
                    check(fields != nil && (fields?["local"] is NSNull) && (fields?["session"] is NSNull), "devtoolscommands: \(label) local and session storage removed")
                    check(!(fields?["cookie"] as? String ?? "p20a_").contains("p20a_"), "devtoolscommands: \(label) cookie removed")
                    check((fields?["databases"] as? [String])?.contains("p20a") == false, "devtoolscommands: \(label) IndexedDB removed")
                    if !isWebKit { check((fields?["caches"] as? [String])?.contains("p20a") == false, "devtoolscommands: \(label) Cache Storage removed") }
                    check(fields?["http"] as? String != nil && fields?["http"] as? String != cacheBefore[label], "devtoolscommands: \(label) HTTP cache removed")
                    done()
                }
            }
        }
        step { [self] done in evaluate(page(), "typeof window.p20aDocumentMarker") { value in
            check(value as? String == "undefined", "devtoolscommands: cleared tab reloads"); done()
        } }
        step { [self] done in asyncEvaluate(other(), """
            return localStorage.getItem('p20a') === 'neighbor' && sessionStorage.getItem('p20a') === 'neighbor'
                && document.cookie.includes('p20a_neighbor=keep') && (!('caches' in window) || (await caches.keys()).includes('p20a'))
                && (await indexedDB.databases()).some(d=>d.name==='p20a');
            """) { value in check(value as? Bool == true, "devtoolscommands: different site's storage and cookie survive"); done() } }
        step { [self] done in asyncEvaluate(other(), "return await (await fetch('/http-cache-neighbor')).text();") { value in
            check(value as? String == cacheBefore["neighbor"], "devtoolscommands: different site's HTTP cache survives"); done()
        } }
        step { done in
            guard thirdPartySeeded else { done(); return }
            evaluate(page(), """
                window.p20aThirdParty = null;
                addEventListener('message', e => { if(e.data?.p20aThirdParty !== undefined) window.p20aThirdParty=e.data.p20aThirdParty; });
                const f=document.createElement('iframe'); f.src='http://\(neighborHost):\(otherPort)/thirdparty-read'; document.body.append(f); true;
                """) { _ in done() }
        }
        wait(1)
        step { [self] done in
            guard thirdPartySeeded else { done(); return }
            evaluate(page(), "window.p20aThirdParty") { value in
                check(value as? Bool == true, "devtoolscommands: another site's third-party cookie survives in the original partition"); done()
            }
        }
        step { [self] done in evaluate(separateTab, "localStorage.getItem('p20a') === 'separate-profile' && document.cookie.includes('p20a_separate=keep')") { value in
            check(value as? Bool == true, "devtoolscommands: another profile's same-site data survives"); done()
        } }
        step { [self] done in evaluate(privateTab, "localStorage.getItem('p20a') === 'private' && document.cookie.includes('p20a_private=keep')") { value in
            check(value as? Bool == true, "devtoolscommands: private window data survives both clear attempts"); done()
        } }
        run { [self] in
            guard let fixtureProfile else { return }
            secureCacheTab = c.engineWindow.openTab(url: URL(string: "http://localhost:\(port)/"), profile: fixtureProfile, foreground: false)
        }
        step { [self] done in
            guard isWebKit else { done(); return }
            waitUntil({ secureCacheTab?.title == "Developer commands" }, timeout: 10) { done() }
        }
        step { [self] done in
            guard isWebKit else { done(); return }
            asyncEvaluate(secureCacheTab, "const c=await caches.open('p20a-secure'); await c.put('/cache-entry',new Response('cached')); return (await caches.keys()).includes('p20a-secure');") { value in
                check(value as? Bool == true, "devtoolscommands: WebKit Cache Storage seeded on trustworthy localhost"); done()
            }
        }
        step { [self] done in
            guard let tab = secureCacheTab else { done(); return }
            tab.clearSiteDataAndReload { result in
                if case .success = result { check(true, "devtoolscommands: WebKit localhost cache clear completed") }
                else { check(false, "devtoolscommands: WebKit localhost cache clear: \(result)") }
                done()
            }
        }
        wait(0.5)
        step { [self] done in
            guard isWebKit else { done(); return }
            asyncEvaluate(secureCacheTab, "return !(await caches.keys()).includes('p20a-secure');") { value in
                check(value as? Bool == true, "devtoolscommands: WebKit Cache Storage removed"); done()
            }
        }
        step { [self] done in
            guard let tab = page() else { done(); return }
            tab.showTaskManager { result in
                if case .failure(.unavailable) = result { check(true, "devtoolscommands: task manager limitation explicit") }
                else { check(false, "devtoolscommands: unexpected task manager result: \(result)") }
                done()
            }
        }
        run { [self] in
            separateTab?.close(); privateTab?.close(); secureCacheTab?.close(); secureCacheTab = nil
            fixtureTabs.values.forEach { $0.close() }; fixtureTabs.removeAll(); fixtureProfile = nil
            #if canImport(AircCore)
            if let privateProfile, let chromium = app?.engine as? ChromiumEngine { chromium.releaseOffTheRecordProfile(privateProfile) }
            #endif
            check(NSApp.windows.filter { $0.title == "Developer Tools" }.isEmpty,
                  "devtoolscommands: no orphan native developer windows, including hidden hosts")
            server?.stop(); neighbor?.stop()
        }
        step { [self] done in
            guard isWebKit else { done(); return }
            func remove(_ left: Int) {
                WKWebsiteDataStore.remove(forIdentifier: webKitStoreID) { error in
                    if error != nil, left > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { remove(left - 1) }; return }
                    check(error == nil, "devtoolscommands: owned persistent WebKit store removed: \(error?.localizedDescription ?? "ok")")
                    done()
                }
            }
            remove(10)
        }
    }

    /// Bounded CDP read of the scratch process's frontend; never touches another app or changes focus.
    private func developerFrontendRead(_ expression: String, completion: @escaping (String?, Any?) -> Void) {
        guard let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--remote-debugging-port=") }),
              let port = Int(flag.split(separator: "=").last ?? "") else {
            check(false, "devtoolscommands: frontend evidence requires scratch remote-debugging-port"); completion(nil, nil); return
        }
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/version")!)
                let info = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let socket = URLSession.shared.webSocketTask(with: URL(string: info["webSocketDebuggerUrl"] as! String)!)
                socket.resume()
                let timeout = DispatchWorkItem { socket.cancel(with: .goingAway, reason: nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
                defer { timeout.cancel(); socket.cancel(with: .goingAway, reason: nil) }
                var serial = 0
                func call(_ method: String, _ params: [String: Any], session: String? = nil) async throws -> [String: Any] {
                    serial += 1; let id = serial
                    var message: [String: Any] = ["id": id, "method": method, "params": params]
                    if let session { message["sessionId"] = session }
                    try await socket.send(.data(try JSONSerialization.data(withJSONObject: message)))
                    while true {
                        let response = try await socket.receive()
                        let bytes: Data
                        switch response { case .string(let text): bytes = Data(text.utf8); case .data(let data): bytes = data; @unknown default: continue }
                        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                        if object["id"] as? Int == id { return object["result"] as? [String: Any] ?? object }
                    }
                }
                let targets = try await call("Target.getTargets", ["filter": [[:]]])
                let list = targets["targetInfos"] as? [[String: Any]] ?? []
                guard let target = list.first(where: { ($0["url"] as? String)?.hasPrefix("devtools://") == true }),
                      let id = target["targetId"] as? String else { completion(nil, nil); return }
                let attached = try await call("Target.attachToTarget", ["targetId": id, "flatten": true])
                let reply = try await call("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": true], session: attached["sessionId"] as? String)
                completion(id, (reply["result"] as? [String: Any])?["value"])
            } catch { check(false, "devtoolscommands: frontend read: \(error)"); completion(nil, nil) }
        }
    }
}
#endif
