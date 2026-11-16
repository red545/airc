// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
#if canImport(AircCore)
import AircCore
#endif
extension SnapshotRunner {
    /// `--script paritypagebubbles`: Chromium bubbles that Chrome anchors on its toolbar and that asked for the tab's
    /// BrowserView, which Airc's windows don't have (the same null as FedCM's 0.1.17 crash). Since engine
    /// 037-media-remoting-dialog.patch and 038-webauthn-ambient-dialog.patch they parent on the window's modal-dialog
    /// parent at the page's top right corner (airc_page_bubble_hooks.h).
    /// - Media remoting ("Optimize fullscreen casting?", asked when a Cast mirroring session could remote a fullscreen
    ///   video): shown through the same coordinator by the engine's test hook (`--airc-test=modalDialogs`); "No thanks"
    ///   and "Optimize" reach the caller and the bubble goes.
    /// - WebAuthn ambient sign-in (`uiMode: 'passive'`, upstream feature WebAuthenticationAmbientSignin, off by
    ///   default; the run passes `--enable-features=WebAuthenticationAmbientSignin`): a DevTools virtual authenticator
    ///   with two fixture passkeys for localhost; the bubble lists both, choosing one signs in; with one passkey Airc
    ///   shows the bubble's "Sign in" (Chrome's page-action chip needs a toolbar).
    /// - Safety Tip ("Did you mean google.com?" on a lookalike domain, on by default; 039-page-info-anchor.patch): the
    ///   bubble Chrome aligns with Page Info, here at the page's top left. Needs `--host-resolver-rules=MAP goolge.com
    ///   127.0.0.1` (skipped without it, so nothing reaches the real host) and `--disable-features=HttpsUpgrades`.
    /// The dialogs are read and pressed through their own accessibility (in-process, our own windows). WebKit has
    /// neither: the page's request settles or stays pending without a crash.
    func parityPageBubblesScenario() {
        var server: LocalPageServer?, tabID = "", serverPort: UInt16 = 0
        let page = { self.c.engineTab(for: tabID) }
        let rp = """
            <title>Page bubbles fixture</title>
            <pre id='out'></pre>
            <script>
            const out = document.getElementById('out');
            const say = (k, v) => { document.body.dataset[k] = v; out.textContent += k + ': ' + v + '\\n'; };
            const b64 = buf => btoa(String.fromCharCode(...new Uint8Array(buf)));
            say('api', window.PublicKeyCredential ? 'webauthn' : 'none');
            (window.PublicKeyCredential && PublicKeyCredential.getClientCapabilities
              ? PublicKeyCredential.getClientCapabilities() : Promise.resolve({}))
              .then(c => say('ambient', String(!!c.ambientGet)), e => say('ambient', 'error:' + e.name));
            window.ambient = key => {
              delete document.body.dataset[key];
              navigator.credentials.get({uiMode: 'passive', mediation: 'conditional', publicKey: {
                  challenge: new Uint8Array(16), rpId: 'localhost', timeout: 60000,
                  userVerification: 'discouraged', allowCredentials: []}})
                .then(c => say(key, 'ok:' + b64(c.rawId)), e => say(key, 'error:' + e.name));
              return true;
            };
            </script>
            """
        step { [self] done in
            server = LocalPageServer(pages: ["/rp": rp])
            server?.start { port in
                // localhost: a secure context that is also a valid WebAuthn RP ID (an IP address is not).
                guard let port, let tab = try? c.store.openTab(url: "http://localhost:\(port)/rp", inSpace: c.currentSpaceID) else {
                    check(false, "pagebubbles: loopback page"); done(); return
                }
                serverPort = port; tabID = tab.id; c.reloadAll(animated: false); c.show(tab.id, focus: false)
                waitUntil({ page()?.title == "Page bubbles fixture" && page()?.isLoading == false }, timeout: 15) { done() }
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
        // Views widgets in our own process, through the formal NSAccessibility protocol (as in ParityFedCmCheck).
        struct AXItem { let role: String; let text: String; let element: NSAccessibilityProtocol }
        func axItems(_ window: NSWindow) -> [AXItem] {
            var out: [AXItem] = []
            func walk(_ e: Any, depth: Int) {
                guard depth < 40, let obj = e as? NSObject, let el = e as? NSAccessibilityProtocol else { return }
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
        func bubbles() -> [(window: NSWindow, items: [AXItem])] {
            NSApp.windows.filter { $0 !== c.window && $0.isVisible && NSStringFromClass(type(of: $0)).contains("NativeWidget") }
                .map { ($0, axItems($0)) }.filter { !$0.items.isEmpty }
        }
        func texts() -> [String] { bubbles().flatMap { $0.items.map(\.text) } }
        func windowDump() -> String {
            NSApp.windows.map { "\(NSStringFromClass(type(of: $0)))#\($0.windowNumber) vis=\($0.isVisible) \(NSStringFromRect($0.frame)) ax=\(axItems($0).count)" }
                .joined(separator: " | ")
        }
        func button(_ words: [String]) -> NSAccessibilityProtocol? {
            for b in bubbles() {
                if let item = b.items.first(where: { item in item.role == "AXButton" && words.contains { item.text.hasPrefix($0) } }) {
                    return item.element
                }
            }
            return nil
        }
        func press(_ e: NSAccessibilityProtocol?) {
            guard let e, (e as? NSObject)?.responds(to: NSSelectorFromString("accessibilityPerformPress")) == true else { return }
            _ = e.accessibilityPerformPress()
        }
        /// The bubble lies over Airc's window, in the page's top right quarter (where Chrome's toolbar button would be).
        func checkPlacement(_ label: String) {
            guard let w = bubbles().map(\.window).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                return note("pagebubbles windows (\(label)): \(windowDump())")
            }
            let main = c.window.frame, f = w.frame
            check(main.contains(NSPoint(x: f.maxX - 20, y: f.maxY - 20)) && f.midX > main.midX && f.maxY > main.midY,
                  "pagebubbles Chromium \(label): the bubble is at the top right of Airc's window (bubble \(NSStringFromRect(f)), window \(NSStringFromRect(main)))")
        }
        var chromium = false, gate = false
        step { [self] done in
            #if canImport(AircCore)
            chromium = page() is ChromiumTab
            #endif
            if !chromium { note("pagebubbles WebKit: no media remoting or ambient sign-in UI; checking the request doesn't break the page") }
            done()
        }
        // Media remoting: "No thanks", then "Optimize".
        func remoting(_ choice: String, expect: Bool, _ done: @escaping () -> Void) {
            #if canImport(AircCore)
            guard let tab = page() as? ChromiumTab else { return done() }
            var answer: Bool?
            // Looked up at run time, so the check also runs (and skips this part) on an engine before 037.
            typealias Show = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Bool) -> Void) -> Bool
            let selector = NSSelectorFromString("showMediaRemotingDialogForTesting:")
            let shown = class_getInstanceMethod(type(of: tab.core), selector).map {
                unsafeBitCast(method_getImplementation($0), to: Show.self)(tab.core, selector) { answer = $0 }
            } ?? false
            if !shown {
                gate = false
                note("SKIP pagebubbles media remoting: no test hook in this launch (--airc-test=modalDialogs) or no Cast in this profile")
                return done()
            }
            gate = true
            waitUntil({ button(["Optimize"]) != nil }, timeout: 10) { [self] in
                check(button(["Optimize"]) != nil && button(["No thanks"]) != nil,
                      "pagebubbles Chromium media remoting (\(choice)): the bubble asks Optimize / No thanks (\(texts().prefix(8)))")
                checkPlacement("media remoting (\(choice))")
                // Past Views' input protection right after a bubble shows.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { press(button([choice])) }
                waitUntil({ answer != nil }, timeout: 10) { [self] in
                    check(answer == expect, "pagebubbles Chromium media remoting: \(choice) answers \(expect) (\(answer.map(String.init) ?? "no answer"))")
                    waitUntil({ button(["Optimize"]) == nil }, timeout: 5) {
                        self.check(button(["Optimize"]) == nil, "pagebubbles Chromium media remoting (\(choice)): the bubble goes"); done()
                    }
                }
            }
            #else
            done()
            #endif
        }
        step { done in guard chromium else { return done() }; remoting("No thanks", expect: false, done) }
        wait(0.5)
        step { done in guard chromium, gate else { return done() }; remoting("Optimize", expect: true, done) }
        wait(0.5)
        // WebAuthn ambient sign-in with a virtual authenticator (DevTools WebAuthn domain).
        var ambientOn = false, authenticator = ""
        func dt(_ method: String, _ params: [String: Any], _ then: @escaping ([String: Any]?, String?) -> Void) {
            #if canImport(AircCore)
            guard let engine = self.app?.engine as? ChromiumEngine, let tab = page() else { return then(nil, "no tab") }
            engine.devToolsCall(method, params: params, in: tab, completion: then)
            #else
            then(nil, "no engine")
            #endif
        }
        // A throwaway P-256 key for the fixture passkeys (PKCS#8), generated for this check only.
        let key = "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgEVmIHjMjLRD2EqXxRxftxVRh8OAdG45e6F1SBLfNV1ehRANCAARCMh6V4tzqDoAVxohSVDjcklPnzKcObaM+9XpTf5w5+DAU127rlQ+0CNEamWonshpZNQ/d1Vuf5kenBXK/aVea"
        let one = Data("fixture-passkey-1".utf8).base64EncodedString(), two = Data("fixture-passkey-2".utf8).base64EncodedString()
        func credential(_ id: String, _ user: String, _ name: String) -> [String: Any] {
            ["credentialId": id, "isResidentCredential": true, "rpId": "localhost", "privateKey": key, "signCount": 0,
             "userHandle": Data(user.utf8).base64EncodedString(), "userName": "\(user)@example.com", "userDisplayName": name]
        }
        step { [self] done in
            guard chromium else { return done() }
            waitFor("ambient", timeout: 5) { value in
                ambientOn = value == "true"
                guard ambientOn else {
                    self.note("SKIP pagebubbles ambient sign-in: the page has no ambientGet capability (\(value ?? "no answer")); run with --enable-features=WebAuthenticationAmbientSignin")
                    return done()
                }
                // Airc's DevTools helper detaches when no call is pending, which would drop the virtual
                // authenticator between calls: one call stays pending (until the page resolves it) for the sequence.
                #if canImport(AircCore)
                (page() as? ChromiumTab)?.core.devToolsCall("Runtime.evaluate", params: [
                    "expression": "new Promise(r => { window.__holdDevTools = r; })", "awaitPromise": true], timeout: 150) { _, _ in }
                #endif
                dt("WebAuthn.enable", ["enableUI": true]) { _, error in
                    let options: [String: Any] = ["protocol": "ctap2", "transport": "internal", "hasResidentKey": true,
                                                  "hasUserVerification": true, "isUserVerified": true,
                                                  "automaticPresenceSimulation": true]
                    dt("WebAuthn.addVirtualAuthenticator", ["options": options]) { result, error2 in
                        authenticator = result?["authenticatorId"] as? String ?? ""
                        self.check(!authenticator.isEmpty, "pagebubbles ambient: virtual authenticator (\(error ?? error2 ?? "ok"))")
                        dt("WebAuthn.addCredential", ["authenticatorId": authenticator, "credential": credential(one, "fixture-one", "Fixture One")]) { _, e1 in
                            dt("WebAuthn.addCredential", ["authenticatorId": authenticator, "credential": credential(two, "fixture-two", "Fixture Two")]) { _, e2 in
                                self.check(e1 == nil && e2 == nil, "pagebubbles ambient: two fixture passkeys (\(e1 ?? e2 ?? "ok"))")
                                done()
                            }
                        }
                    }
                }
            }
        }
        // Two passkeys: the bubble lists both; choosing "Fixture Two" signs in with it.
        step { [self] done in
            guard chromium, ambientOn, !authenticator.isEmpty else { return done() }
            page()?.evaluate("ambient('two')") { _ in }
            waitUntil({ button(["Fixture Two", "fixture-two"]) != nil }, timeout: 15) { [self] in
                check(button(["Fixture One", "fixture-one"]) != nil && button(["Fixture Two", "fixture-two"]) != nil,
                      "pagebubbles Chromium ambient, two passkeys: the bubble lists both (\(texts().prefix(10)))")
                checkPlacement("ambient, two passkeys")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { press(button(["Fixture Two", "fixture-two"])) }
                waitFor("two", timeout: 15) { value in
                    self.check(value == "ok:" + two, "pagebubbles Chromium ambient, two passkeys: choosing Fixture Two signs in with it (\(value ?? "no answer"))")
                    self.waitUntil({ button(["Fixture One", "fixture-one"]) == nil }, timeout: 5) {
                        self.check(button(["Fixture One", "fixture-one"]) == nil, "pagebubbles Chromium ambient, two passkeys: the bubble goes"); done()
                    }
                }
            }
        }
        wait(0.5)
        // One passkey: Chrome would show a toolbar page-action chip; Airc shows the bubble's "Sign in".
        step { [self] done in
            guard chromium, ambientOn, !authenticator.isEmpty else { return done() }
            dt("WebAuthn.removeCredential", ["authenticatorId": authenticator, "credentialId": two]) { _, error in
                self.check(error == nil, "pagebubbles ambient: one passkey left (\(error ?? "ok"))")
                page()?.evaluate("ambient('one')") { _ in }
                self.waitUntil({ button(["Sign In", "Sign in"]) != nil }, timeout: 15) { [self] in
                    let shown = button(["Sign In", "Sign in"]) != nil && texts().contains { $0.contains("Fixture One") || $0.contains("fixture-one") }
                    check(shown, "pagebubbles Chromium ambient, one passkey: the bubble offers Sign in as Fixture One (\(texts().prefix(10)))")
                    guard shown else { return done() }
                    checkPlacement("ambient, one passkey")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { press(button(["Sign In", "Sign in"])) }
                    waitFor("one", timeout: 15) { value in
                        self.check(value == "ok:" + one, "pagebubbles Chromium ambient, one passkey: Sign in signs in (\(value ?? "no answer"))")
                        self.waitUntil({ button(["Sign In", "Sign in"]) == nil }, timeout: 5) {
                            self.check(button(["Sign In", "Sign in"]) == nil, "pagebubbles Chromium ambient, one passkey: the bubble goes")
                            dt("WebAuthn.removeVirtualAuthenticator", ["authenticatorId": authenticator]) { _, _ in
                                dt("WebAuthn.disable", [:]) { _, _ in
                                    page()?.evaluate("window.__holdDevTools && window.__holdDevTools(); true") { _ in done() }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Safety Tip: a character swap of a top domain (goolge.com), served by the loopback server.
        let lookalikeMapped = CommandLine.arguments.contains { $0.contains("MAP goolge.com 127.0.0.1") }
        step { [self] done in
            guard chromium else { return done() }
            guard lookalikeMapped, serverPort != 0 else {
                note("SKIP pagebubbles Safety Tip: launch with --host-resolver-rules=MAP goolge.com 127.0.0.1 (nothing is sent to the real host without it)")
                return done()
            }
            // A scratch profile has no Safety Tips component config, and without one Chromium shows no tip.
            var config = false
            #if canImport(AircCore)
            if let tab = page() as? ChromiumTab {
                typealias Use = @convention(c) (AnyObject, Selector) -> Bool
                let selector = NSSelectorFromString("useEmptySafetyTipsConfigForTesting")
                config = class_getInstanceMethod(type(of: tab.core), selector).map {
                    unsafeBitCast(method_getImplementation($0), to: Use.self)(tab.core, selector)
                } ?? false
            }
            #endif
            if !config { note("pagebubbles Safety Tip: no empty-config test hook (engine before 039 or no --airc-test=modalDialogs); a tip needs the downloaded component") }
            page()?.evaluate("location.href = 'http://goolge.com:\(serverPort)/rp'; true") { _ in }
            waitUntil({ texts().contains { $0.contains("Did you mean") } }, timeout: 20) { [self] in
                let url = page()?.url?.host ?? "?"
                let shown = texts().contains { $0.contains("google.com") }
                check(shown, "pagebubbles Chromium Safety Tip: on \(url) the bubble asks Did you mean google.com? (\(texts().prefix(8)))")
                guard shown else { return done() }
                // Aligned with Page Info: the page's top left (Chrome: the location icon).
                if let w = bubbles().map(\.window).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                    let main = c.window.frame, f = w.frame
                    check(main.contains(NSPoint(x: f.minX + 20, y: f.maxY - 20)) && f.midX < main.maxX - 200,
                          "pagebubbles Chromium Safety Tip: the bubble is at the top left of the page (bubble \(NSStringFromRect(f)), window \(NSStringFromRect(main)))")
                } else { note("pagebubbles windows (Safety Tip): \(windowDump())") }
                // Close, never "Yes, continue" (that would open the real google.com).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { press(button(["Close"])) }
                waitUntil({ !texts().contains { $0.contains("Did you mean") } }, timeout: 5) { [self] in
                    check(!texts().contains { $0.contains("Did you mean") }, "pagebubbles Chromium Safety Tip: Close dismisses it")
                    check(page()?.url?.host == "goolge.com", "pagebubbles Chromium Safety Tip: the tab stays on the page (\(page()?.url?.absoluteString ?? "nil"))")
                    done()
                }
            }
        }
        // WebKit: a passive conditional request on a page with no passkeys must not break the page.
        step { [self] done in
            guard !chromium else { return done() }
            page()?.evaluate("ambient('webkit')") { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                page()?.evaluate("document.title") { title in
                    self.check(title as? String == "Page bubbles fixture", "pagebubbles WebKit: the page still answers after a passive request (\(title ?? "nil"))")
                    done()
                }
            }
        }
        wait(1)
        run { [self] in
            if !bubbles().isEmpty { note("pagebubbles: left over: \(windowDump())") }
            check(page() != nil, "pagebubbles: the page's tab is still open")
            server?.stop(); finish()
        }
    }
}
#endif
