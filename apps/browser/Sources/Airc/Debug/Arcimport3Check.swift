// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircImport
import AircKit
import AppKit
import Security
import SQLite3

/// arcimport3 (E11): the real user's path through onboarding's Logins step, end to end, on a synthetic Arc only.
/// Never the owner's Arc folder, never the login keychain, never Arc's own "Arc Safe Storage" item: the runner makes a
/// scratch keychain with a known password and one item under a test service name ("Airc Test …"), and the check reads
/// it through the real Keychain API (`SecItemCopyMatching`, limited to that keychain). Real driver clicks press
/// Import logins and Try Again (FG=1, AIRC_REAL_KEYS=1, dedicated session).
///   - macOS denying the key (simulated, as the prompt's Deny answers): sites' storage still comes over; logins and
///     cookies say why they weren't read, and Try Again (a real click) asks again, now reading the scratch item.
///   - Then, on Chromium, pages on loopback origins: the site reads its imported localStorage; the imported cookies are
///     sent; the partitioned (CHIPS) cookie sits in its partition and reaches only the embedded frame; the imported
///     login is offered and fills the form; the HTTP authentication login fills the browser's sign-in box.
///   - Every row's outcome in the results view, and the line saying what never comes over.
///   - WebKit: the step says logins come with the Chromium engine and reads nothing.
extension SnapshotRunner {
    func arcImport3Scenario() {
        let root = dir.appendingPathComponent("arcimport3")
        let arc = root.appendingPathComponent("Arc")
        let fm = FileManager.default
        let seen = SeenRequests()
        var page = "", alt = "", homeID = ""
        var server: LocalPageServer?
        let keychain = TestArcKeychain.current
        let chromium = app?.credentialSink.acceptsCredentials == true

        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.requestHandler = { r in
                seen.add(r)
                switch r.path {
                case "/storage":
                    return .init(body: "<title>storage</title><script>document.title='ls:'+localStorage.getItem('token')</script>")
                case "/cookies":
                    return .init(body: "<title>cookies</title><p>\(r.headers["cookie"] ?? "")</p>")
                case "/top":
                    return .init(body: "<title>top</title><iframe src='\(alt)/frame' width=300 height=80></iframe>")
                case "/frame":
                    return .init(body: "<p>frame</p>")
                case "/login":
                    return .init(body: """
                        <title>login</title><style>input{display:block;width:260px;height:32px;margin:14px}</style>
                        <form action="/done" method="post"><input id="username" name="username" autocomplete="username">
                        <input id="password" name="password" type="password" autocomplete="current-password"><button>Sign in</button></form>
                        """)
                case "/auth":
                    let want = "Basic " + Data("staff:a3-basic-pw".utf8).base64EncodedString()
                    if r.headers["authorization"] == want { return .init(body: "<title>authorized</title>") }
                    return .init(status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"Staff\""], body: "<title>unauthorized</title>")
                default:
                    return .init(body: "<title>a3</title>")
                }
            }
            guard let server else { check(false, "arcimport3: the loopback page server starts"); return done() }
            server.start { port in
                page = "http://127.0.0.1:\(port ?? 0)"
                alt = "http://localhost:\(port ?? 0)"
                done()
            }
        }
        run { [self] in
            guard let keychain else {
                return skip("arcimport3: no scratch keychain (AIRC_TEST_ARC_KEYCHAIN, AIRC_TEST_ARC_SAFE_STORAGE): the real Keychain path isn't part of this run")
            }
            do { try Arcimport3Fixture.write(arc, page: page, alt: alt, secret: keychain.secret) }
            catch { check(false, "arcimport3: synthetic Arc written (\(error))") }
            OnboardingController.testArcDirectory = arc
            ArcExtensionChecklist.testStoreBase = URL(string: "http://127.0.0.1:9")
            app?.startOnboarding(mode: .rerun, atImport: true)
        }
        step { [self] done in
            guard keychain != nil else { return done() }
            waitUntil({ self.app?.onboarding?.model.hasArc == true }, timeout: 30, then: done)
        }
        run { [self] in
            guard keychain != nil, let m = app?.onboarding?.model else { return }
            m.includeLogins = true
            m.onImportEverything?()
        }
        step { [self] done in
            guard keychain != nil else { return done() }
            waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30, then: done)
        }
        // On to the Logins step, as Continue does.
        for _ in 0..<3 {
            run { [self] in
                guard let o = app?.onboarding, o.model.result != nil, o.model.step != .logins, o.model.step < .logins else { return }
                o.next()
            }
            wait(0.6)
        }
        run { [self] in
            guard keychain != nil, let m = app?.onboarding?.model else { return }
            homeID = m.result?.profileIDs["arc-profile:Default"] ?? ""
            check(m.step == .logins, "arcimport3: onboarding reaches the Logins step after the import (\(m.step))")
            if chromium {
                check(m.loginsAvailable && m.siteStorageAvailable, "arcimport3: Chromium: the step brings logins, cookies and sites' storage")
            } else {
                check(!m.loginsAvailable && TestAnchors.frames["onboarding.logins.import"] == nil,
                      "arcimport3: WebKit: the step says logins come with the Chromium engine and offers no Import logins")
            }
        }
        step { [self] done in
            guard keychain != nil, let w = app?.onboarding?.window else { return done() }
            captureWindow(w, name: "arcimport3-logins-step", rounded: 24, done)
        }

        // MARK: macOS denies the key: the rest still comes over

        func activate(_ window: @escaping () -> NSWindow?) {
            step { done in
                NSApp.activate(ignoringOtherApps: true)
                window()?.makeKeyAndOrderFront(nil)
                self.waitUntil({ NSApp.isActive && window()?.isKeyWindow == true }, timeout: 3, then: done)
            }
        }
        /// A real click (the UI driver) on an anchor of `window`; FAIL-ENV when the driver refuses, then a posted press so
        /// the rest of the check still runs (labelled).
        func realClick(_ anchor: String, _ what: String, _ window: @escaping () -> NSWindow?, fallback: @escaping () -> Void) {
            step { [self] done in
                guard let w = window(), let host = w.contentView, let v = TestAnchors.view(anchor, in: host), let primary = NSScreen.screens.first else {
                    check(false, "arcimport3 [real click] \(what): on screen (\(anchor))"); return done()
                }
                let r = w.convertToScreen(v.convert(v.bounds, to: nil))
                UIDriverClient.run(["--click", String(Double(r.midX.rounded())), String(Double((primary.frame.maxY - r.midY).rounded()))]) { ok, out in
                    if ok { self.note("arcimport3 [real click] \(what)") } else {
                        self.note("FAIL-ENV arcimport3 [real click] \(what): \(out); pressing it in-app [posted]")
                        fallback()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                }
            }
        }
        let onboardingWindow: () -> NSWindow? = { self.app?.onboarding?.window }
        func outcome() -> CredentialImport.Outcome? {
            if case .done(let o)? = app?.onboarding?.model.logins { return o }
            return nil
        }
        if chromium {
            run { TestArcKeychain.state.simulate(errSecAuthFailed) }
            activate(onboardingWindow)
            realClick("onboarding.logins.import", "Import logins", onboardingWindow) { self.app?.onboarding?.model.onImportLogins?() }
            step { [self] done in
                guard keychain != nil else { return done() }
                waitUntil({ outcome() != nil }, timeout: 30, then: done)
            }
            wait(0.6)
            run { [self] in
                guard keychain != nil else { return }
                guard let o = outcome() else { return check(false, "arcimport3: denied: the import finished (\(String(describing: app?.onboarding?.model.logins)))") }
                let whole = o.rows.filter { $0.whole && $0.profileID == homeID }
                check(o.keychainProblem?.hasPrefix("Keychain access to “Arc Safe Storage” was denied") == true
                      && whole.map(\.status) == [.skipped, .skipped] && whole.allSatisfy { $0.reason.contains("stayed locked") }
                      && o.siteDataImported == 1 && o.loginsImported + o.cookiesImported == 0 && !o.isFailure
                      && Set(o.retryable.map(\.kind)) == [.login, .cookies] && TestArcKeychain.state.reads == 0,
                      "arcimport3: macOS denied the key: sites' storage still came over; logins and cookies say why and can be tried again — \(o.summary)")
                check(TestAnchors.frames["results.retry"] != nil && TestAnchors.frames["results.never"] != nil,
                      "arcimport3: the results show Try Again and what never comes over")
            }
            step { [self] done in
                guard keychain != nil, let w = onboardingWindow() else { return done() }
                captureWindow(w, name: "arcimport3-denied", rounded: 24, done)
            }
            // The person allows it this time: Try Again reads the scratch item through the real Keychain API.
            run { TestArcKeychain.state.simulate(nil) }
            activate(onboardingWindow)
            realClick("results.retry", "Try Again", onboardingWindow) { _ = CredentialImport.retry() }
            step { [self] done in
                guard keychain != nil else { return done() }
                waitUntil({ CredentialImport.Session.shared.outcome?.attempt == 2 && !CredentialImport.Session.shared.retrying }, timeout: 30, then: done)
            }
            wait(0.6)
            run { [self] in
                guard keychain != nil else { return }
                guard let o = CredentialImport.Session.shared.outcome, o.attempt == 2 else { return check(false, "arcimport3: Try Again ran") }
                func row(_ kind: CredentialImport.ResultRow.Kind, _ site: String, _ user: String = "") -> CredentialImport.ResultRow? {
                    o.rows.first { $0.kind == kind && $0.site == site && (user.isEmpty || $0.username == user) && !$0.whole }
                }
                check(TestArcKeychain.state.reads == 1 && o.keychainProblem == nil && o.loginsImported == 3 && o.cookiesImported == 3 && o.siteDataImported == 1,
                      "arcimport3: Try Again read the scratch keychain's item (\(TestArcKeychain.state.reads) real read) — \(o.summary)")
                // Every row, with its outcome and why.
                let lines = o.rows.filter { !$0.whole }.map { "\($0.kind.rawValue) \($0.site) \($0.username) \($0.status.rawValue)" + ($0.reason.isEmpty ? "" : " · \($0.reason)") }
                note("arcimport3: rows: " + lines.joined(separator: " | "))
                check(row(.login, "127.0.0.1", "a3-user")?.status == .imported
                      && row(.login, "127.0.0.1", "staff")?.status == .imported && row(.login, "127.0.0.1", "staff")?.detail == "the browser's sign-in box"
                      && row(.login, "fed.example", "fed-user")?.status == .imported && row(.login, "fed.example", "fed-user")?.detail == "with Google"
                      && row(.login, "com.a3.app")?.status == .skipped && row(.login, "com.a3.app")?.reason.contains("no website is linked to the app") == true
                      && row(.login, "never.example")?.reason == "Arc was set to never save passwords here"
                      && row(.login, "v11.example", "old-key")?.status == .failed && row(.login, "v11.example", "old-key")?.reason.contains("v11") == true,
                      "arcimport3: login rows: form, HTTP authentication and federated imported; the Android app's and never-save skipped; the v11 one failed, each with why")
                check(row(.cookies, "127.0.0.1")?.status == .imported && row(.cookies, "127.0.0.1")?.count == 2
                      && row(.cookies, "localhost")?.status == .imported
                      && row(.cookies, "old.example")?.reason == "Already expired in Arc",
                      "arcimport3: cookie rows: 127.0.0.1's two and the partitioned one imported; the expired one skipped")
                let local = o.rows.first { $0.kind == .siteData && $0.site == "127.0.0.1" && $0.detail.hasPrefix("local storage") }
                check(local?.status == .imported && local?.detail == "local storage · 1 item"
                      && o.rows.contains { $0.kind == .siteData && $0.detail == "offline data" && $0.site == "127.0.0.1" }
                      && o.rows.contains { $0.kind == .siteData && $0.reason == ArcSiteStorage.partitionedReason && $0.count == 1 }
                      && o.rows.contains { $0.kind == .siteData && $0.reason == ArcSiteStorage.workersReason },
                      "arcimport3: site rows: 127.0.0.1's localStorage imported; its IndexedDB, the partitioned storage and service workers named")
                check(o.federated.first?.provider == "accounts.google.com" && TestAnchors.frames["results.federated"] != nil,
                      "arcimport3: the results say to use Sign in with Google on fed.example")
            }
            step { [self] done in
                guard keychain != nil, let w = onboardingWindow() else { return done() }
                captureWindow(w, name: "arcimport3-results", rounded: 24, done)
            }
        }
        run { [self] in app?.onboarding?.requestClose() }
        wait(0.8)

        // MARK: Chromium: the sites use what came over

        #if canImport(AircCore)
        var tabID = ""
        let tab = { self.c.engineTab(for: tabID) }
        /// `title`: the store's title for the tab; `loads` false for a page that stops at the browser's sign-in box.
        func open(_ url: @escaping () -> String, title: String, loads: Bool = true) {
            run { [self] in
                guard chromium, keychain != nil, let home = c.store.space(sourceID: "arc-space:s-home"),
                      let t = try? c.store.openTab(url: url(), inSpace: home.id, title: title) else { return }
                tabID = t.id
                c.switchToSpace(home.id, animated: false)
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            step { [self] done in
                guard chromium, keychain != nil else { return done() }
                guard loads else { return done() }
                waitUntil({ tab()?.isLoading == false && !(tab()?.title ?? "").isEmpty }, timeout: 10, then: done)
            }
            wait(0.4)
        }
        open({ page + "/storage" }, title: "storage")
        run { [self] in
            guard chromium, keychain != nil else { return }
            check(tab()?.title == "ls:arc-local-value", "arcimport3: Chromium: the site's page reads its imported localStorage (\(tab()?.title ?? "-"))")
        }
        open({ page + "/cookies" }, title: "cookies")
        run { [self] in
            guard chromium, keychain != nil else { return }
            let sent = seen.last("/cookies")?.headers["cookie"] ?? ""
            check(sent.contains("a3sid=arc-cookie") && sent.contains("a3session=arc-session") && !sent.contains("a3chips"),
                  "arcimport3: Chromium: the imported cookies are sent to 127.0.0.1 (Cookie: \(Self.names(sent)))")
        }
        open({ page + "/top" }, title: "top")
        wait(0.8)
        step { [self] done in
            guard chromium, keychain != nil, let engine = app?.engine as? ChromiumEngine, let t = tab() else { return done() }
            let framed = seen.last("/frame")?.headers["cookie"] ?? ""
            engine.devToolsCall("Storage.getCookies", params: [:], in: t) { reply, error in
                let cookies = reply?["cookies"] as? [[String: Any]] ?? []
                let chips = cookies.first { $0["name"] as? String == "a3chips" }
                let key = chips?["partitionKey"] as? [String: Any]
                self.check(chips != nil && key?["topLevelSite"] as? String == "http://127.0.0.1" && key?["hasCrossSiteAncestor"] as? Bool == true,
                           "arcimport3: Chromium: the partitioned cookie is in 127.0.0.1's partition (\(key.map { "\($0)" } ?? error ?? "not found"))")
                self.note("arcimport3: the frame from localhost inside 127.0.0.1 sent Cookie: \(Self.names(framed))")
                self.check(framed.contains("a3chips=in-portal"),
                           "arcimport3: Chromium: the partitioned cookie reaches localhost's frame inside 127.0.0.1")
                done()
            }
        }
        open({ alt + "/cookies" }, title: "cookies")
        run { [self] in
            guard chromium, keychain != nil else { return }
            let sent = seen.last("/cookies")?.headers["cookie"] ?? ""
            check(!sent.contains("a3chips"), "arcimport3: Chromium: localhost on its own doesn't get the partitioned cookie (Cookie: \(Self.names(sent)))")
        }

        // The imported login: offered on its site's form, and it fills it.
        open({ page + "/login" }, title: "login")
        step { [self] done in
            guard chromium, keychain != nil, let engine = app?.engine as? ChromiumEngine, let t = tab() else { return done() }
            engine.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('username').focus()", "userGesture": true], in: t) { _, _ in
                if self.c.prompts.passwords.view == nil { engine.showAutofillSuggestions(in: t, passwords: true) }
                self.waitUntil({ self.c.prompts.passwords.view != nil }, timeout: 5, then: done)
            }
        }
        run { [self] in
            guard chromium, keychain != nil else { return }
            let picker = c.prompts.passwords
            check(picker.choices.contains { $0.username == "a3-user" } && !picker.choices.contains { $0.username == "staff" },
                  "arcimport3: Chromium: the imported login is offered on its site's form (\(picker.choices.map(\.username)))")
            if let i = picker.choices.firstIndex(where: { $0.username == "a3-user" }), let p = tab() { _ = picker.accept?(p, picker.choices[i].index) }
        }
        wait(0.8)
        step { [self] done in
            guard chromium, keychain != nil, let engine = app?.engine as? ChromiumEngine, let t = tab() else { return done() }
            engine.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('username').value+'|'+document.getElementById('password').value",
                                                           "userGesture": true, "returnByValue": true], in: t) { reply, _ in
                let value = (reply?["result"] as? [String: Any])?["value"] as? String
                self.check(value == "a3-user|a3-password-1", "arcimport3: Chromium: choosing it fills the form with the imported login (\(value.map { $0.hasSuffix("a3-password-1") ? "a3-user|••••" : $0 } ?? "nil"))")
                done()
            }
        }

        // The HTTP authentication login fills the browser's sign-in box; Return sends it.
        var dialogWindow: NSWindow?
        var windowsBefore: Set<Int> = []
        run { windowsBefore = Set(NSApp.windows.map(\.windowNumber)) }
        open({ page + "/auth" }, title: "auth", loads: false)
        // The engine's Views sign-in box: the window that appears with the challenge (the engine's dialog test hook
        // needs a launch this check doesn't use), found by its own accessibility tree.
        step { [self] done in
            guard chromium, keychain != nil else { return done() }
            let found = { NSApp.windows.first { !windowsBefore.contains($0.windowNumber) && $0.isVisible && $0.className.contains("NativeWidget") } }
            waitUntil({ found() != nil }, timeout: 10) {
                dialogWindow = found()
                if dialogWindow == nil {
                    let auth = seen.last("/auth")
                    self.check(false, "arcimport3: Chromium: the site asks with the browser's sign-in box (title \(tab()?.title ?? "-"), "
                               + "server saw /auth \(auth == nil ? "never" : "with" + (auth?.headers["authorization"] == nil ? "out" : "") + " credentials"), "
                               + "new windows \(NSApp.windows.filter { !windowsBefore.contains($0.windowNumber) }.map { "\(type(of: $0)) visible \($0.isVisible)" }))")
                }
                done()
            }
        }
        wait(1.0)
        run { [self] in
            guard chromium, keychain != nil, let w = dialogWindow else { return }
            let fields = Self.textFieldValues(w)
            note("arcimport3: sign-in box fields: \(fields.map { $0.isEmpty ? "(empty)" : ($0 == "staff" ? $0 : "••••") })")
            // Views exposes its fields only to an assistive app, so this is a note; Return below is the proof.
            if !fields.isEmpty { check(fields.contains("staff"), "arcimport3: Chromium: the sign-in box shows the imported username") }
        }
        activate({ dialogWindow })
        step { [self] done in
            guard chromium, keychain != nil, dialogWindow != nil else { return done() }
            UIDriverClient.run(["--key", "return", "--pid", "\(getpid())"]) { ok, out in
                if !ok {
                    self.note("FAIL-ENV arcimport3 [real key] Return in the sign-in box: \(out)")
                }
                self.waitUntil({ tab()?.title == "authorized" }, timeout: 8, then: done)
            }
        }
        run { [self] in
            guard chromium, keychain != nil, dialogWindow != nil else { return }
            check(tab()?.title == "authorized",
                  "arcimport3: Chromium [real key]: the sign-in box was filled with the imported HTTP authentication login: Return sends it and the site lets it in (\(tab()?.title ?? "-"), server saw "
                  + (seen.last("/auth")?.headers["authorization"] == nil ? "no credentials)" : "credentials)"))
            if let engine = app?.engine as? ChromiumEngine, let t = tab() { engine.cancelModalDialog(in: t) }
        }
        run { [self] in if !tabID.isEmpty { c.closeTab(tabID) } }
        #endif

        run { [self] in
            server?.stop()
            OnboardingController.testArcDirectory = nil
            ArcExtensionChecklist.testStoreBase = nil
            TestArcKeychain.state.simulate(nil)
            try? fm.removeItem(at: root)
        }
    }

    /// Cookie names only (never their values), for the log.
    static func names(_ header: String) -> String {
        header.split(separator: ";").map { String($0.split(separator: "=").first ?? "").trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
    }

    /// The text fields' values in a Views dialog, through its own accessibility tree (in-process, our own window).
    static func textFieldValues(_ window: NSWindow) -> [String] {
        var out: [String] = []
        func walk(_ e: Any, depth: Int) {
            // The attribute form: one meaning for any element (Views' own and AppKit's).
            guard depth < 14, let el = e as? NSObject else { return }
            if el.accessibilityAttributeValue(.role) as? String == NSAccessibility.Role.textField.rawValue,
               let v = el.accessibilityAttributeValue(.value) as? String { out.append(v) }
            for child in el.accessibilityAttributeValue(.children) as? [Any] ?? [] { walk(child, depth: depth + 1) }
        }
        if let v = window.contentView { walk(v, depth: 0) }
        return out
    }
}

/// Requests the loopback server saw (its own queue writes, the check reads on main).
final class SeenRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [LocalPageServer.Request] = []
    func add(_ r: LocalPageServer.Request) { lock.lock(); all.append(r); lock.unlock() }
    func last(_ path: String) -> LocalPageServer.Request? { lock.lock(); defer { lock.unlock() }; return all.last { $0.path == path } }
}

/// arcimport3: the check's scratch keychain item in place of "Arc Safe Storage". Only with all of
/// AIRC_TEST_ARC_KEYCHAIN (a `.keychain-db` file outside ~/Library/Keychains), AIRC_TEST_ARC_SAFE_STORAGE (a service
/// named "Airc Test …", never Arc's) and the synthetic secret the runner stored in it; test builds only.
struct TestArcKeychain: Sendable {
    let path: String
    let service: String
    let keychainPassword: String
    /// The item's value, which the synthetic Arc's rows are encrypted with (never read from Arc).
    let secret: String

    static var current: TestArcKeychain? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["AIRC_TEST_ARC_KEYCHAIN"], path.hasSuffix(".keychain-db"), !path.contains("/Library/Keychains/"),
              let service = env["AIRC_TEST_ARC_SAFE_STORAGE"], service.hasPrefix("Airc Test "), service != ArcSafeStorage.Item.arc.service,
              let secret = env["AIRC_TEST_ARC_SECRET"], !secret.isEmpty else { return nil }
        return TestArcKeychain(path: path, service: service, keychainPassword: env["AIRC_TEST_ARC_KEYCHAIN_PASSWORD"] ?? "", secret: secret)
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var simulated: OSStatus?
        private var count = 0
        /// The answer macOS's prompt would give (errSecAuthFailed: Deny); nil reads the item.
        func simulate(_ status: OSStatus?) { lock.lock(); simulated = status; lock.unlock() }
        var answer: OSStatus? { lock.lock(); defer { lock.unlock() }; return simulated }
        func read() { lock.lock(); count += 1; lock.unlock() }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    static let state = State()

    /// Reads the scratch item through `SecItemCopyMatching`, limited to the scratch keychain (opened and unlocked here,
    /// never added to the search list), or gives the simulated answer through the same handling.
    var keySource: CredentialImport.KeySource {
        let me = self
        return {
            if let status = TestArcKeychain.state.answer {
                return try ArcSafeStorage.deriveKey(password: ArcSafeStorage.readPassword { _, _ in status })
            }
            TestArcKeychain.state.read()
            var keychain: SecKeychain?
            guard SecKeychainOpen(me.path, &keychain) == errSecSuccess, let keychain else { throw ImportError.keychainNotFound }
            if !me.keychainPassword.isEmpty {
                _ = SecKeychainUnlock(keychain, UInt32(me.keychainPassword.utf8.count), me.keychainPassword, true)
            }
            return try ArcSafeStorage.deriveKey(password: ArcSafeStorage.readPassword(item: .init(service: me.service, account: "Arc"),
                                                                                       searchList: [keychain]))
        }
    }
}

/// The synthetic Arc for arcimport3: Home (Default) and Work (Profile 1), and in Default, Chromium 156's own schemas:
/// logins of every kind, cookies (one partitioned, one session, one expired), localStorage for the loopback page (and
/// one partitioned item), an IndexedDB folder and a Service Worker folder. Encrypted with `secret`, the value of the
/// scratch keychain's item.
enum Arcimport3Fixture {
    static func write(_ root: URL, page: String, alt: String, secret: String) throws {
        try ImportAcceptanceFixture.sidebar(root)
        try ImportAcceptanceFixture.json(root, "User Data/Local State",
                                         ["profile": ["info_cache": ["Default": ["name": "Synthetic Home"], "Profile 1": ["name": "Synthetic Work"]]]])
        let d = root.appendingPathComponent("User Data/Default")
        try ImportAcceptanceFixture.folders(root, ["Default", "Profile 1"])
        _ = try ImportAcceptanceFixture.sqlite(d.appendingPathComponent("History"), """
            CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
            INSERT INTO urls VALUES('\(page)/storage','Synthetic page',6,1,\(ImportAcceptanceFixture.chromeTime(days: -1)),0);
            """)
        let key = try ArcSafeStorage.deriveKey(password: Data(secret.utf8))
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        func enc(_ data: Data) throws -> String { hex(try ArcSafeStorage.encryptForTests(data, key: key)) }
        func login(_ origin: String, _ realm: String, _ user: String, _ blob: String, scheme: Int = 0, federation: String = "", never: Int = 0) -> String {
            "INSERT INTO logins(origin_url, action_url, username_element, username_value, password_element, password_value, signon_realm, date_created, blacklisted_by_user, scheme, federation_url) VALUES('\(origin)','\(origin)','username','\(user)','password',X'\(blob)','\(realm)',13300000000000000,\(never),\(scheme),'\(federation)');"
        }
        _ = try ImportAcceptanceFixture.sqlite(d.appendingPathComponent("Login Data"), """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR); INSERT INTO meta VALUES('version','43');
            CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR,
              password_element VARCHAR, password_value BLOB, submit_element VARCHAR, signon_realm VARCHAR NOT NULL, date_created INTEGER NOT NULL,
              blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL, password_type INTEGER, times_used INTEGER, form_data BLOB,
              display_name VARCHAR, icon_url VARCHAR, federation_url VARCHAR, skip_zero_click INTEGER, generation_upload_status INTEGER,
              possible_username_pairs BLOB, id INTEGER PRIMARY KEY AUTOINCREMENT, date_last_used INTEGER NOT NULL DEFAULT 0,
              moving_blocked_for BLOB, date_password_modified INTEGER NOT NULL DEFAULT 0,
              UNIQUE (origin_url, username_element, username_value, password_element, signon_realm));
            """
            + login(page + "/", page + "/", "a3-user", try enc(Data("a3-password-1".utf8)))
            + login(page + "/", page + "/Staff", "staff", try enc(Data("a3-basic-pw".utf8)), scheme: 1)
            + login("https://fed.example/", "federation://fed.example/accounts.google.com", "fed-user", "", federation: "https://accounts.google.com")
            + login("android://h@com.a3.app/", "android://h@com.a3.app/", "app-user", try enc(Data("a3-app".utf8)))
            + login("https://never.example/", "https://never.example/", "", "", never: 1)
            + login("https://v11.example/", "https://v11.example/", "old-key", hex(Data("v11".utf8) + Data(repeating: 7, count: 16))))
        let later = ImportAcceptanceFixture.chromeTime(days: 30), earlier = ImportAcceptanceFixture.chromeTime(days: -3)
        func cookie(_ host: String, _ name: String, _ value: String, expires: Int64, secure: Bool = false, partition: String = "") throws -> String {
            let blob = try enc(ArcSafeStorage.digest(host) + Data(value.utf8))
            return "INSERT INTO cookies VALUES(\(earlier),'\(host)','\(partition)','\(name)','',X'\(blob)','/',\(expires),\(secure ? 1 : 0),0,\(earlier),"
                + "\(expires == 0 ? 0 : 1),\(expires == 0 ? 0 : 1),1,\(partition.isEmpty ? 1 : 0),\(secure ? 2 : 1),\(secure ? 443 : 80),\(earlier),0,\(partition.isEmpty ? 0 : 1));"
        }
        _ = try ImportAcceptanceFixture.sqlite(d.appendingPathComponent("Cookies"), """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version','24'); INSERT INTO meta VALUES('last_compatible_version','24');
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL, name TEXT NOT NULL,
              value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL,
              is_httponly INTEGER NOT NULL, last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
              priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL, source_port INTEGER NOT NULL,
              last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL, has_cross_site_ancestor INTEGER NOT NULL);
            """
            + (try cookie("127.0.0.1", "a3sid", "arc-cookie", expires: later))
            + (try cookie("127.0.0.1", "a3session", "arc-session", expires: 0))
            + (try cookie("localhost", "a3chips", "in-portal", expires: later, secure: true, partition: "http://127.0.0.1"))
            + (try cookie(".old.example", "gone", "x", expires: earlier)))
        func ls(_ storageKey: String, _ k: String) -> Data { Data("_\(storageKey)".utf8) + Data([0, 1]) + Data(k.utf8) }
        try LevelDBFixture.write([
            (Data("VERSION".utf8), Data("1".utf8)),
            (ls(page, "token"), Data([1]) + Data("arc-local-value".utf8)),
            (ls(alt + "/^0" + page, "embedded"), Data([1]) + Data("inside".utf8)),
        ], to: d.appendingPathComponent("Local Storage/leveldb"))
        let port = URL(string: page)?.port ?? 0
        for folder in ["IndexedDB/http_127.0.0.1_\(port).indexeddb.leveldb", "Service Worker/Database"] {
            try FileManager.default.createDirectory(at: d.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }
}
#endif
