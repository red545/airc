// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
#if canImport(AircCore)
import AircCore
#endif
extension SnapshotRunner {
    /// FedCM (navigator.credentials.get({identity})) on a loopback relying party with a fake identity provider.
    /// 0.1.17 crashed in FedCmAccountSelectionView::CreateDialogWidget on Google's "Continue with Google": Chromium's
    /// FedCM dialogs looked for the tab's views widget, which Airc's windows don't have (0.1.18 turned FedCM off).
    /// Since 036-fedcm-dialogs.patch they parent on the window's modal-dialog parent: on Chromium this drives the real
    /// dialogs through their own accessibility (in-process, our own windows): the loading dialog, the account chooser
    /// in button and passive mode, choosing an account (the token reaches the page) and closing it (the page gets an
    /// error). WebKit has no FedCM; the page falls back to its popup there, as Google's library does.
    func parityFedCmScenario() {
        var server: LocalPageServer?, tabID = "", origin = "", requests: [String] = []
        let page = { self.c.engineTab(for: tabID) }
        let rp = """
            <title>FedCM fixture</title>
            <style>body{margin:0;font:16px system-ui}button{display:block;width:300px;height:60px;margin:0}</style>
            <button id='active'>Continue with the fixture IdP</button><button id='passive'>Passive</button>
            <button id='required'>Passive, always ask</button>
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
            function signIn(mode, mediation) {
              delete document.body.dataset[mode];
              if (!('IdentityCredential' in window) || !navigator.credentials) { say(mode, 'fallback:no-api'); popup(mode); return; }
              const config = location.origin + '/idp/config.json';
              navigator.credentials.get({mediation, identity: {mode, providers: [{configURL: config, clientId: 'fixture-rp', nonce: 'n1'}]}})
                .then(c => say(mode, 'token:' + c.token))
                .catch(e => { say(mode, 'error:' + e.name); popup(mode); });
            }
            document.getElementById('active').onclick = () => signIn('active', 'optional');
            document.getElementById('passive').onclick = () => signIn('passive', 'optional');
            document.getElementById('required').onclick = () => signIn('passive', 'required');
            </script>
            """
        func json(_ body: String, cors: Bool = false, delay: TimeInterval = 0) -> LocalPageServer.Page {
            var headers = ["Content-Type": "application/json"]
            if cors { headers["Access-Control-Allow-Origin"] = origin; headers["Access-Control-Allow-Credentials"] = "true" }
            return LocalPageServer.Page(headers: headers, body: body, delay: delay)
        }
        step { [self] done in
            server = LocalPageServer(pages: [:])
            server?.requestHandler = { request in
                let line = "\(request.method) \(request.path)"
                DispatchQueue.main.async { requests.append(line) }
                switch request.path {
                case "/rp": return LocalPageServer.Page(body: rp)
                case "/.well-known/web-identity": return json("{\"provider_urls\":[\"\(origin)/idp/config.json\"]}")
                case "/idp/config.json":
                    return json("{\"accounts_endpoint\":\"/idp/accounts\",\"client_metadata_endpoint\":\"/idp/client_metadata\","
                        + "\"id_assertion_endpoint\":\"/idp/assertion\",\"login_url\":\"/idp/login\","
                        + "\"branding\":{\"background_color\":\"#1a73e8\",\"color\":\"#ffffff\",\"name\":\"Fixture IdP\"}}")
                case "/idp/accounts":
                    // A slow IdP keeps the button-mode loading dialog up long enough to see it.
                    return json("{\"accounts\":[{\"id\":\"1\",\"name\":\"Fixture Person\",\"given_name\":\"Fixture\","
                        + "\"email\":\"person@fixture.invalid\",\"approved_clients\":[]}]}", delay: 1.5)
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
        // FedCM's dialogs are views widgets in our own process: their texts and buttons, through the formal
        // NSAccessibility protocol (BridgedContentView answers accessibilityChildren with the views root; the
        // attribute form gives nothing there).
        struct AXItem { let role: String; let text: String; let element: NSAccessibilityProtocol }
        func axItems(_ window: NSWindow) -> [AXItem] {
            var out: [AXItem] = []
            func walk(_ e: Any, depth: Int) {
                guard depth < 24, let el = e as? NSAccessibilityProtocol, let obj = e as? NSObject else { return }
                func has(_ name: String) -> Bool { obj.responds(to: NSSelectorFromString(name)) }
                let role = has("accessibilityRole") ? el.accessibilityRole()?.rawValue ?? "" : ""
                let text = [has("accessibilityTitle") ? el.accessibilityTitle() : nil,
                            has("accessibilityLabel") ? el.accessibilityLabel() : nil,
                            has("accessibilityValue") ? el.accessibilityValue() as? String : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                if !text.isEmpty { out.append(AXItem(role: role, text: text, element: el)) }
                for child in (has("accessibilityChildren") ? el.accessibilityChildren() : nil) ?? [] { walk(child, depth: depth + 1) }
            }
            if let v = window.contentView { walk(v, depth: 0) }
            return out
        }
        /// Visible Chromium views windows with something to read: FedCM's dialog or bubble (never the main window or the
        /// transparent modal parent, which has no texts).
        func dialogs() -> [(window: NSWindow, items: [AXItem])] {
            NSApp.windows.filter { $0 !== c.window && $0.isVisible && NSStringFromClass(type(of: $0)).contains("NativeWidget") }
                .map { ($0, axItems($0)) }.filter { !$0.items.isEmpty }
        }
        func texts() -> [String] { dialogs().flatMap { $0.items.map(\.text) } }
        /// Every window and child window, for the log when a dialog isn't found.
        func windowDump() -> String {
            NSApp.windows.map { w in
                let kids = (w.childWindows ?? []).map { NSStringFromClass(type(of: $0)) }
                return "\(NSStringFromClass(type(of: w)))#\(w.windowNumber) vis=\(w.isVisible) lvl=\(w.level.rawValue) "
                    + "\(NSStringFromRect(w.frame)) ax=\(axItems(w).count) kids=\(kids)"
            }.joined(separator: " | ")
        }
        func button(_ words: [String], exactly: Bool = false) -> NSAccessibilityProtocol? {
            for d in dialogs() {
                if let item = d.items.first(where: { item in
                    // Title and label repeat each other ("Continue Continue"): match on the first half for exact names.
                    let name = String(item.text.prefix((item.text.count - 1) / 2))
                    return item.role == "AXButton" && words.contains { exactly ? (name == $0 || item.text == $0) : item.text.contains($0) }
                }) { return item.element }
            }
            return nil
        }
        func press(_ e: NSAccessibilityProtocol?) {
            guard let e, (e as? NSObject)?.responds(to: NSSelectorFromString("accessibilityPerformPress")) == true else { return }
            _ = e.accessibilityPerformPress()
        }
        var chromium = false
        step { [self] done in
            #if canImport(AircCore)
            chromium = page() is ChromiumTab
            #endif
            read("api") { api in
                let api = api ?? "?"
                if chromium {
                    check(api == "IdentityCredential,login", "fedcm Chromium: FedCM is on (IdentityCredential, navigator.login: \(api))")
                } else {
                    note("fedcm WebKit: page sees \(api)")
                }
                done()
            }
        }
        func clickActive(_ done: @escaping () -> Void) {
            guard let tab = page() else { check(false, "fedcm: missing tab"); return done() }
            #if canImport(AircCore)
            if let engine = self.app?.engine as? ChromiumEngine, tab is ChromiumTab {
                // A real click on the page (user activation), as on Google's button.
                let click = ["x": 100, "y": 30, "button": "left", "clickCount": 1] as [String: Any]
                engine.devToolsCall("Input.dispatchMouseEvent", params: click.merging(["type": "mousePressed"]) { $1 }, in: tab) { _, _ in
                    engine.devToolsCall("Input.dispatchMouseEvent", params: click.merging(["type": "mouseReleased"]) { $1 }, in: tab) { _, _ in done() }
                }
                return
            }
            #endif
            tab.evaluate("document.getElementById('active').click(); true") { _ in done() }
        }
        func clickPassive(required: Bool, _ done: @escaping () -> Void) {
            page()?.evaluate("document.getElementById('\(required ? "required" : "passive")').click(); true") { _ in done() }
        }
        /// The chooser for the fixture account; the dialog must lie over Airc's window (anchored to the page).
        func expectChooser(_ label: String, _ done: @escaping () -> Void) {
            waitUntil({ button(["Fixture Person", "person@fixture.invalid"]) != nil }, timeout: 15) { [self] in
                let shown = dialogs()
                if shown.isEmpty { note("fedcm windows (\(label)): \(windowDump())") }
                else { note("fedcm dialog (\(label)): \(shown.flatMap { $0.items.map { "\($0.role):\($0.text)" } }.prefix(20))") }
                check(button(["Fixture Person", "person@fixture.invalid"]) != nil, "fedcm Chromium \(label): the account chooser shows the account (\(texts().prefix(12)))")
                // The dialog itself, not the transparent modal parent that also lists its elements.
                if let w = shown.map(\.window).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                    let main = c.window.frame
                    check(main.intersects(w.frame) && w.screen != nil, "fedcm Chromium \(label): the dialog is over Airc's window (dialog \(NSStringFromRect(w.frame)), window \(NSStringFromRect(main)))")
                }
                done()
            }
        }
        func choose(_ key: String, _ label: String, _ done: @escaping () -> Void) {
            // Views ignores presses in the first moments after a dialog shows (double-click guard): wait them out.
            // A new account asks once more ("Continue"); a returning one signs in at once.
            var continued = false, shownAt: Date?
            let deadline = Date().addingTimeInterval(20)
            func poll() {
                read(key) { value in
                    if let value {
                        self.check(value == "token:fixture-token", "fedcm Chromium \(label): choosing the account gives the page its token (\(value))")
                        self.waitUntil({ dialogs().isEmpty }, timeout: 5) {
                            self.check(dialogs().isEmpty, "fedcm Chromium \(label): the dialog closes after sign-in")
                            done()
                        }
                        return
                    }
                    if !continued, let next = button(["Continue"], exactly: true) {
                        if shownAt == nil { shownAt = Date() }
                        if Date().timeIntervalSince(shownAt!) > 0.8 { continued = true; press(next) }
                    }
                    if Date() > deadline {
                        self.check(false, "fedcm Chromium \(label): no token after choosing the account (dialog \(Array(Set(texts())).sorted().prefix(16)))")
                        self.note("fedcm IdP requests so far: \(requests)"); return done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                press(button(["Fixture Person", "person@fixture.invalid"]))
                poll()
            }
        }
        func cancel(_ key: String, _ label: String, _ done: @escaping () -> Void) {
            let close = button(["Close", "Cancel"])
            check(close != nil, "fedcm Chromium \(label): the dialog has a close button (\(texts().prefix(12)))")
            // Past the double-click guard (Views drops presses right after a dialog shows).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { press(button(["Close", "Cancel"])) }
            waitFor(key, timeout: 15) { [self] value in
                check(value?.hasPrefix("error:") == true, "fedcm Chromium \(label): closing the dialog rejects the request (\(value ?? "no answer"))")
                waitUntil({ dialogs().isEmpty }, timeout: 5) {
                    self.check(dialogs().isEmpty, "fedcm Chromium \(label): the dialog goes"); done()
                }
            }
        }
        // Button mode, closed: the loading dialog (the IdP answers after 1.5 s), then the chooser, then its close button.
        step { [self] done in
            guard chromium else { return done() }
            clickActive {
                self.waitUntil({ !dialogs().isEmpty }, timeout: 1.4) {
                    self.check(!dialogs().isEmpty, "fedcm Chromium button mode: the loading dialog shows while the IdP answers (\(texts().prefix(8)))")
                    if dialogs().isEmpty { self.note("fedcm windows at loading: \(windowDump())") }
                    expectChooser("button mode") { cancel("active", "button mode", done) }
                }
            }
        }
        wait(0.5)
        // Passive mode ("Sign in to … with …"): a new account, chosen and confirmed.
        step { done in
            guard chromium else { return done() }
            clickPassive(required: false) { expectChooser("passive mode") { choose("passive", "passive mode", done) } }
        }
        wait(0.5)
        // Button mode again, now a returning account: chosen.
        step { done in
            guard chromium else { return done() }
            clickActive { expectChooser("button mode, returning") { choose("active", "button mode, returning", done) } }
        }
        wait(0.5)
        // Passive mode that always asks (no automatic re-authentication), closed.
        step { done in
            guard chromium else { return done() }
            clickPassive(required: true) { expectChooser("passive mode, closed") { cancel("passive", "passive mode, closed", done) } }
        }
        // WebKit: no FedCM; both modes settle and the button falls back to the popup.
        step { [self] done in
            guard !chromium else { return done() }
            clickPassive(required: false) {
                waitFor("passive", timeout: 20) { value in
                    self.check(value != nil, "fedcm WebKit: passive request settles (\(value ?? "no answer"))")
                    clickActive {
                        waitFor("active", timeout: 20) { value in
                            self.check(value != nil, "fedcm WebKit: button-mode request settles (\(value ?? "no answer"))")
                            waitFor("popup", timeout: 15) { popup in
                                self.check(popup == "signed-in", "fedcm WebKit: sign-in falls back to its popup (\(popup ?? "no message"))")
                                done()
                            }
                        }
                    }
                }
            }
        }
        wait(1)
        run { [self] in
            note("fedcm IdP requests: \(requests)")
            check(page() != nil, "fedcm: the relying party's tab is still open")
            server?.stop(); finish()
        }
    }
}
#endif
