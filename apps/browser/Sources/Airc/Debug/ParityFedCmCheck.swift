// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
#if canImport(AircCore)
import AircCore
#endif
extension SnapshotRunner {
    /// FedCM (navigator.credentials.get({identity})) on a loopback relying party with a fake identity provider.
    /// Chromium's FedCM dialogs need the tab's views widget, which Airc's windows don't have: 0.1.17 crashed in
    /// FedCmAccountSelectionView::CreateDialogWidget on Google's "Continue with Google". Until Airc shows those
    /// dialogs, the Chromium engine starts with FedCM off, so the API is absent and sign-in falls back to its popup,
    /// as Google Identity Services does. WebKit has no FedCM; the same page must settle there without a crash.
    func parityFedCmScenario() {
        var server: LocalPageServer?, tabID = "", origin = ""
        let page = { self.c.engineTab(for: tabID) }
        let rp = """
            <title>FedCM fixture</title>
            <style>body{margin:0;font:16px system-ui}button{display:block;width:300px;height:60px;margin:0}</style>
            <button id='active'>Continue with the fixture IdP</button><button id='passive'>Passive</button>
            <pre id='out'></pre>
            <script>
            const out = document.getElementById('out');
            const say = (k, v) => { document.body.dataset[k] = v; out.textContent += k + ': ' + v + '\\n'; };
            say('api', ('IdentityCredential' in window ? 'IdentityCredential' : 'none') + ',' + (navigator.login ? 'login' : 'nologin'));
            addEventListener('message', e => { if (e.data && e.data.fixture) say('popup', e.data.fixture); });
            // Like Google's library: only the button (a click) opens the popup; passive mode just gives up.
            function popup(mode) {
              if (mode !== 'active') return;
              const w = window.open('/popup?mode=' + mode, 'fixture-signin', 'popup,width=420,height=520');
              if (!w) say('popup', 'blocked');
            }
            function signIn(mode) {
              if (!('IdentityCredential' in window) || !navigator.credentials) { say(mode, 'fallback:no-api'); popup(mode); return; }
              const config = location.origin + '/idp/config.json';
              navigator.credentials.get({identity: {mode, providers: [{configURL: config, clientId: 'fixture-rp', nonce: 'n1'}]}})
                .then(c => say(mode, 'token:' + c.token))
                .catch(e => { say(mode, 'error:' + e.name); popup(mode); });
            }
            document.getElementById('active').onclick = () => signIn('active');
            document.getElementById('passive').onclick = () => signIn('passive');
            </script>
            """
        func json(_ body: String, cors: Bool = false) -> LocalPageServer.Page {
            var headers = ["Content-Type": "application/json"]
            if cors { headers["Access-Control-Allow-Origin"] = origin; headers["Access-Control-Allow-Credentials"] = "true" }
            return LocalPageServer.Page(headers: headers, body: body)
        }
        step { [self] done in
            server = LocalPageServer(pages: [:])
            server?.requestHandler = { request in
                switch request.path {
                case "/rp": return LocalPageServer.Page(body: rp)
                case "/.well-known/web-identity": return json("{\"provider_urls\":[\"\(origin)/idp/config.json\"]}")
                case "/idp/config.json":
                    return json("{\"accounts_endpoint\":\"/idp/accounts\",\"client_metadata_endpoint\":\"/idp/client_metadata\","
                        + "\"id_assertion_endpoint\":\"/idp/assertion\",\"login_url\":\"/idp/login\","
                        + "\"branding\":{\"background_color\":\"#1a73e8\",\"color\":\"#ffffff\",\"name\":\"Fixture IdP\"}}")
                case "/idp/accounts":
                    return json("{\"accounts\":[{\"id\":\"1\",\"name\":\"Fixture Person\",\"given_name\":\"Fixture\","
                        + "\"email\":\"person@fixture.invalid\",\"approved_clients\":[\"fixture-rp\"]}]}")
                case "/idp/client_metadata": return json("{\"privacy_policy_url\":\"\(origin)/pp\",\"terms_of_service_url\":\"\(origin)/tos\"}")
                case "/idp/assertion": return json("{\"token\":\"fixture-token\"}", cors: true)
                case "/idp/login": return LocalPageServer.Page(headers: ["Set-Login": "logged-in"], body: "<title>IdP login</title>signed in")
                case "/popup":
                    // The popup fallback a sign-in library opens when FedCM isn't there: it reports back and closes.
                    return LocalPageServer.Page(body: "<title>Fixture sign-in</title><script>"
                        + "opener && opener.postMessage({fixture:'signed-in'}, '*'); setTimeout(() => close(), 300);</script>")
                default: return nil
                }
            }
            server?.start { port in
                guard let port, let tab = try? c.store.openTab(url: "http://127.0.0.1:\(port)/rp", inSpace: c.currentSpaceID) else {
                    check(false, "fedcm: loopback relying party"); done(); return
                }
                origin = "http://127.0.0.1:\(port)"
                tabID = tab.id; c.reloadAll(animated: false); c.show(tab.id, focus: false)
                waitUntil({ page()?.title == "FedCM fixture" && page()?.isLoading == false }, timeout: 15) { done() }
            }
        }
        wait(1)
        func read(_ key: String, _ result: @escaping (String?) -> Void) {
            page()?.evaluate("document.body.dataset.\(key) || ''") { value in
                let text = value as? String
                result(text?.isEmpty == false ? text : nil)
            }
        }
        func waitFor(_ key: String, timeout: Double, _ then: @escaping (String?) -> Void) {
            let deadline = Date().addingTimeInterval(timeout)
            func poll() {
                read(key) { value in
                    if let value { then(value) } else if Date() > deadline { then(nil) }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll) }
                }
            }
            poll()
        }
        var chromium = false
        step { [self] done in
            #if canImport(AircCore)
            chromium = page() is ChromiumTab
            #endif
            read("api") { api in
                let api = api ?? "?"
                if chromium {
                    check(api == "none,nologin", "fedcm Chromium: FedCM is off until Airc shows its dialogs (IdentityCredential, navigator.login: \(api))")
                } else {
                    note("fedcm WebKit: page sees \(api)")
                }
                done()
            }
        }
        // Passive: the "Sign in to … with …" prompt and auto re-authentication. It needs no click.
        step { [self] done in
            page()?.evaluate("document.getElementById('passive').click(); true") { _ in
                waitFor("passive", timeout: 20) { value in
                    self.check(value != nil, "fedcm \(chromium ? "Chromium" : "WebKit"): passive request settles (\(value ?? "no answer"))")
                    if chromium { self.check(value?.hasPrefix("token:") != true, "fedcm Chromium: passive request shows no FedCM UI") }
                    done()
                }
            }
        }
        // Active ("button") mode, what Google's sign-in button uses: it needs a real click for user activation.
        step { [self] done in
            guard let tab = page() else { check(false, "fedcm: missing tab"); done(); return }
            let finish = {
                waitFor("active", timeout: 20) { value in
                    self.check(value != nil, "fedcm \(chromium ? "Chromium" : "WebKit"): button-mode request settles (\(value ?? "no answer"))")
                    if chromium { self.check(value?.hasPrefix("token:") != true, "fedcm Chromium: button mode shows no FedCM UI") }
                    waitFor("popup", timeout: 15) { popup in
                        self.check(popup == "signed-in", "fedcm \(chromium ? "Chromium" : "WebKit"): sign-in falls back to its popup (\(popup ?? "no message"))")
                        done()
                    }
                }
            }
            #if canImport(AircCore)
            if let engine = self.app?.engine as? ChromiumEngine, tab is ChromiumTab {
                let click = ["x": 100, "y": 30, "button": "left", "clickCount": 1] as [String: Any]
                engine.devToolsCall("Input.dispatchMouseEvent", params: click.merging(["type": "mousePressed"]) { $1 }, in: tab) { _, _ in
                    engine.devToolsCall("Input.dispatchMouseEvent", params: click.merging(["type": "mouseReleased"]) { $1 }, in: tab) { _, _ in finish() }
                }
                return
            }
            #endif
            tab.evaluate("document.getElementById('active').click(); true") { _ in finish() }
        }
        wait(1)
        run { [self] in
            check(page() != nil, "fedcm: the relying party's tab is still open")
            server?.stop(); finish()
        }
    }
}
#endif
