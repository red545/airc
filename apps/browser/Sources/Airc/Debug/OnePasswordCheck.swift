// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script onepassword` (docs/user/extensions.md, "Password managers"): what a password manager's extension needs from
/// Airc, on synthetic fixtures (never a real account, vault or the Mac's keychain):
///
/// - chrome.action.openPopup() from the extension's service worker (1Password's "Unlock 1Password" calls it): the
///   promise resolves, the popup shows under the extension's button (URL field, pinned toolbar button), and the
///   extension gets no activeTab grant from it (unlike a click on its button, which grants it, as in Chrome).
/// - The extensions list (⌘E's run path) still opens the popup.
/// - Native messaging: the fake hosts' manifests in two "other browser" folders (AIRC_NATIVE_HOST_SOURCES, made by the
///   runner before launch) are linked into the run's Chromium/NativeMessagingHosts at startup: first folder wins, a
///   manifest already in Airc's folder is kept, a stale link is removed; chrome.runtime.sendNativeMessage reaches each.
/// - AIRC_OP_EXTENSION=<folder> (optional): the real 1Password extension unpacked with its Web Store key, no account.
///   Its "Unlock 1Password" button sends `request-managed-unlock`, which opens its popup through openPopup: clicked on
///   its "Save passkey?" card or its locked in-field button when either shows. 1Password 8.12.46.29 with no account
///   shows neither (both need an account), so that step is then a SKIP with the reason; with an account and neither
///   shown it's a "fixture changed" red. The log names the 1Password version. Its popup also opens from the extensions
///   list; a passkey request on a localhost page reaches Chromium's own passkey dialog, which the page then cancels.
///
/// Needs the engine's test gate (`--airc-data-dir`, `--airc-test=unpackedExtension,modalDialogs`) and an active, key
/// window (AIRC_UI_DEDICATED_SESSION=1): Chromium refuses openPopup in an inactive window. Chromium only.
extension SnapshotRunner {
    func onePasswordScenario() {
        #if canImport(AircCore)
        guard let engine = app?.engine as? ChromiumEngine else {
            check(false, "onepassword: requires the Chromium engine"); return
        }
        let gate = Self.engineTestGateOpens
        var server: LocalPageServer?
        var port: UInt16 = 0
        var fakeID = ""
        var opID = ""
        var ppID = ""
        var mainTab = ""
        let env = ProcessInfo.processInfo.environment
        let sources = (env["AIRC_NATIVE_HOST_SOURCES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let hosts = AppPaths.chromium.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        var opPage: ChromiumTab?
        func shownPage() -> ChromiumTab? { c.engineTab(for: c.shownTabID ?? "") as? ChromiumTab }
        func key() -> ObjectIdentifier? { shownPage()?.owner.map { ObjectIdentifier($0.core) } }
        func shownPopup() -> ExtensionPopupPanel? { key().flatMap { ExtensionPopupPanel.shown($0) } }
        /// Runs `js` in the shown page every 0.2 s until it gives a non-empty string (or `timeout`).
        func poll(_ js: String, in target: ChromiumTab? = nil, timeout: Double, _ then: @escaping (String) -> Void) {
            let deadline = Date().addingTimeInterval(timeout)
            func once() {
                guard let tab = target ?? shownPage() else { return then("") }
                tab.evaluate(js) { value in
                    let s = value as? String ?? ""
                    if !s.isEmpty || Date() > deadline { then(s) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: once) }
                }
            }
            once()
        }
        /// Asks the synthetic extension's service worker (through its content script) and waits for its answer.
        func ask(_ op: String, _ extra: String = "", timeout: Double = 15, _ then: @escaping (String) -> Void) {
            opPage?.evaluate("document.documentElement.removeAttribute('data-op-\(op)'); window.postMessage({opfake: {op: '\(op)'\(extra)}}, '*'); ''", completion: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                poll("document.documentElement.getAttribute('data-op-\(op)') || ''", in: opPage, timeout: timeout, then)
            }
        }
        func show(_ url: String, title: String, _ done: @escaping () -> Void) {
            guard let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID) else { check(false, "onepassword: open \(url)"); return done() }
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            waitUntil({
                guard let tab = self.c.engineTab(for: t.id) else { return false }
                return title.isEmpty ? !tab.isLoading && tab.url?.absoluteString == url : tab.title == title
            }, timeout: 10) { done() }
        }
        func panelUnder(_ anchor: (view: NSView, rect: NSRect)?, _ panel: NSWindow?) -> String {
            guard let anchor, let panel else { return "no anchor or panel" }
            let a = c.window.convertToScreen(anchor.view.convert(anchor.rect.intersection(anchor.view.bounds), to: nil))
            let content = panel.contentRect(forFrameRect: panel.frame)
            let top = abs(content.maxY - a.minY) <= 1
            let edge = abs(content.minX - a.minX) <= 1 || abs(content.maxX - a.maxX) <= 1
            return top && edge ? "" : "popup \(Self.p09(content)), anchor \(Self.p09(a))"
        }
        func saveView(_ view: NSView, _ name: String) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        func savePicture(_ tab: AircTab?, _ name: String, _ done: @escaping () -> Void) {
            guard let tab else { note("onepassword: no picture for \(name)"); return done() }
            tab.copyPicture(5) { image in
                if let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: self.dir.appendingPathComponent("\(name).png"))
                } else { self.note("onepassword: no picture for \(name)") }
                done()
            }
        }

        /// Settings › Passwords off: a saved Airc login isn't filled when its page loads (engine patch 040); on, it is (the
        /// control). `label` says which extensions are installed by then.
        func fillOnLoad(_ label: String) {
            for on in [true, false] {
                step { [self] done in
                    if label.contains("1Password") && opID.isEmpty || label.contains("Proton") && ppID.isEmpty { return done() }
                    guard let app, let page = shownPage(), let pid = app.profiles.profileID(for: page.profile) else { return done() }
                    app.setAircPasswords(on, profileID: pid)
                    guard let t = try? c.store.openTab(url: "http://localhost:\(port)/login?fill=\(on)-\(label.count)", inSpace: c.currentSpaceID) else { return done() }
                    c.reloadAll(animated: false)
                    c.show(t.id, focus: false)
                    waitUntil({ self.c.engineTab(for: t.id)?.title == "Login page" && self.c.engineTab(for: t.id)?.isLoading == false }, timeout: 10) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            let js = "['user', 'pass'].map(id => document.getElementById(id).matches(':autofill')).join(',')"
                            self.c.engineTab(for: t.id)?.evaluate(js) { value in
                                let filled = value as? String ?? "?"
                                if on {
                                    self.check(filled == "true,true", "onepassword: \(label): with Airc's passwords on, the saved login fills on page load (control: \(filled))")
                                } else {
                                    self.check(filled == "false,false", "onepassword: \(label): with them off, the saved login isn't filled on page load (\(filled))")
                                }
                                savePicture((self.c.engineTab(for: t.id) as? ChromiumTab)?.core, "fillonload-\(on ? "on" : "off")-\(label.replacingOccurrences(of: " ", with: "-"))") {
                                    app.setAircPasswords(true, profileID: pid)
                                    if let main = self.c.store.tab(mainTab) { self.c.show(main.id, focus: false) }
                                    self.waitUntil({ shownPage() === opPage }, timeout: 5) { done() }
                                }
                            }
                        }
                    }
                }
            }
        }

        step { done in
            server = LocalPageServer(pages: [
                "/op": "<title>OP page</title><body style=\"background:#f3ece0;font:15px -apple-system\"><h1>A sign-in page</h1></body>",
                "/login": "<title>Login page</title><body style=\"font:15px -apple-system;padding:40px\"><form action=\"/done\" method=\"post\">"
                    + "<p><input id=\"user\" name=\"username\" autocomplete=\"username\" placeholder=\"Email\"></p>"
                    + "<p><input id=\"pass\" name=\"password\" type=\"password\" autocomplete=\"current-password\" placeholder=\"Password\"></p>"
                    + "<button>Sign in</button></form></body>",
                "/other": "<title>Other page</title><body style=\"background:#e6eef3;font:15px -apple-system\"><h1>Another site</h1></body>",
            ])
            server?.start { p in port = p ?? 0; done() }
        }
        step { [self] done in
            if c.pageToolbar != nil { c.togglePageToolbar() }
            c.sidebarOnRight = false; c.isFullscreen = false
            show("http://localhost:\(port)/op", title: "OP page") {
                mainTab = self.c.shownTabID ?? ""
                opPage = shownPage()
                self.note("onepassword: test gate \(gate), app active \(NSApp.isActive), window key \(self.c.window.isKeyWindow), on active Space \(self.c.window.isOnActiveSpace)")
                done()
            }
        }
        // A saved Airc login for the loopback login page (a made-up account), then fill on page load without extensions.
        step { [self] done in
            guard gate, let profile = shownPage()?.profile as? ChromiumProfile else { return done() }
            let origin = "http://localhost:\(port)/"
            profile.core.importLogins([["origin": origin + "login", "signonRealm": origin, "actionURL": origin + "done",
                                        "username": "fixture@example.com", "password": "fixture-only-pass"]]) { result in
                DispatchQueue.main.async {
                    self.check((result["saved"] as? NSNumber)?.intValue == 1, "onepassword: a made-up Airc login is saved for the login page (\(result["saved"] ?? "?"))")
                    done()
                }
            }
        }
        fillOnLoad("no extensions")

        // The synthetic extension.
        step { [self] done in
            guard gate, let profile = shownPage()?.profile as? ChromiumProfile else { return done() }
            let folder = dir.appendingPathComponent("onepassword-fake", isDirectory: true)
            Self.writeOnePasswordFake(folder)
            profile.core.loadUnpackedExtension(forTesting: folder.path) { id, error in
                DispatchQueue.main.async {
                    if let error { self.note("onepassword: fake extension: \(error)") }
                    fakeID = id ?? ""
                    done()
                }
            }
        }
        step { [self] done in
            guard !fakeID.isEmpty else {
                check(false, "onepassword: needs the engine's test gate (--airc-data-dir, --airc-test=unpackedExtension,modalDialogs)")
                return done()
            }
            // A fresh load of the page, so the new content script runs in it.
            shownPage()?.reload()
            waitUntil({ shownPage()?.isLoading == false && shownPage()?.title == "OP page" }, timeout: 10) {
                poll("document.documentElement.getAttribute('data-opfake') || ''", timeout: 10) { ready in
                    self.check(ready == "ready", "onepassword: the fake extension's content script runs on the page (\(ready))")
                    done()
                }
            }
        }

        // openPopup, unpinned, toolbar off: under the URL field, like the ⌘E list.
        step { [self] done in
            guard !fakeID.isEmpty else { return done() }
            guard c.window.isKeyWindow, NSApp.isActive else {
                note("FAIL-ENV onepassword: openPopup needs the key window of the active app (key \(c.window.isKeyWindow), active \(NSApp.isActive))")
                return done()
            }
            ask("open") { answer in
                let panel = shownPopup()
                self.check(answer == "ok", "onepassword: chrome.action.openPopup() resolves (\(answer.isEmpty ? "no answer" : answer))")
                self.check(panel?.extensionID == fakeID && panel?.panel.isVisible == true && panel?.panel.parent === self.c.window,
                           "onepassword: the popup shows over its window (panel \(panel != nil), visible \(panel?.panel.isVisible ?? false))")
                self.check(panel?.popup?.url.hasPrefix("chrome-extension://\(fakeID)/popup.html") == true,
                           "onepassword: it is the extension's popup page (\(panel?.popup?.url ?? "none"))")
                let where_ = panelUnder(self.c.extensionPopupAnchor(for: fakeID), panel?.panel)
                self.check(where_.isEmpty, "onepassword: under the URL field, its edge on the field's \(where_)")
                let size = panel.map { $0.panel.contentRect(forFrameRect: $0.panel.frame).size } ?? .zero
                self.check(size == NSSize(width: 600, height: 430), "onepassword: the panel takes the popup page's size, 600 × 430 like Proton Pass's (\(Int(size.width)) × \(Int(size.height)))")
                savePicture(panel?.popup, "openpopup-urlfield") {
                    self.c.closeExtensionPopup()
                    self.waitUntil({ shownPopup() == nil }, timeout: 3) {
                        self.check(shownPopup() == nil, "onepassword: the popup closes with the window's popup close")
                        done()
                    }
                }
            }
        }
        // activeTab, on a page the extension has no access to (127.0.0.1; its content script runs on localhost only):
        // openPopup grants none; a click on its button does (Chrome's rule). The service worker opens and probes 2.5 s
        // after the request, once the other page shows.
        step { [self] done in
            guard !fakeID.isEmpty, c.window.isKeyWindow else { return done() }
            var answer = ""
            ask("probe", timeout: 20) { answer = $0 }
            show("http://127.0.0.1:\(port)/other", title: "Other page") {
                self.waitUntil({ !answer.isEmpty }, timeout: 20) {
                    self.check(shownPopup()?.extensionID == fakeID, "onepassword: openPopup opens over the other page too")
                    self.check(answer == "url:none", "onepassword: openPopup gave the extension no access to the tab (activeTab not granted: \(answer))")
                    self.c.closeExtensionPopup()
                    guard let a = self.c.extensionAnchor(for: fakeID) else { return done() }
                    self.c.runExtension(fakeID, anchor: a.view, rect: a.rect)
                    ask("probe-now") { after in
                        self.check(after.hasPrefix("url:http://127.0.0.1"), "onepassword: a click on its button does grant it (\(after))")
                        self.c.closeExtensionPopup()
                        if let t = self.c.store.tab(mainTab) { self.c.show(t.id, focus: false) }
                        self.waitUntil({ shownPage() === opPage }, timeout: 5) { done() }
                    }
                }
            }
        }
        // Pinned, toolbar on: under its toolbar button, trailing edges together.
        step { [self] done in
            guard !fakeID.isEmpty, c.window.isKeyWindow else { return done() }
            c.setExtension(fakeID, pinned: true)
            c.togglePageToolbar()
            ask("open") { answer in
                let panel = shownPopup()
                let anchor = self.c.pageToolbar?.extensionAnchor(for: fakeID)
                let where_ = panelUnder(anchor, panel?.panel)
                self.check(answer == "ok" && panel != nil && where_.isEmpty,
                           "onepassword: pinned in the toolbar, openPopup opens under its button (\(answer)) \(where_)")
                savePicture(panel?.popup, "openpopup-toolbar") {
                    // Escape closes it, as in Chrome.
                    if let p = panel?.panel, let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                                          windowNumber: p.windowNumber, context: nil, characters: "\u{1b}",
                                                                          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(esc, atStart: false)
                    }
                    self.waitUntil({ shownPopup() == nil }, timeout: 3) {
                        self.check(shownPopup() == nil, "onepassword: Escape closes it")
                        self.c.togglePageToolbar()
                        self.c.setExtension(fakeID, pinned: false)
                        done()
                    }
                }
            }
        }
        // The extensions list's run path (⌘E → click a row) still opens the button's popup.
        step { [self] done in
            guard !fakeID.isEmpty, let a = c.extensionAnchor(for: fakeID) else { return done() }
            let before = Set((c.window.childWindows ?? []).map(ObjectIdentifier.init))
            let shown = c.runExtension(fakeID, anchor: a.view, rect: a.rect)
            let panel = (c.window.childWindows ?? []).last { $0 is NSPanel && !before.contains(ObjectIdentifier($0)) }
            check(shown && panel?.isVisible == true, "onepassword: the extensions list opens its popup (shown \(shown))")
            waitUntil({ panel.map { $0.contentRect(forFrameRect: $0.frame).size == NSSize(width: 600, height: 430) } ?? false }, timeout: 5) {
                let size = panel.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
                self.check(size == NSSize(width: 600, height: 430), "onepassword: a click's popup takes its page's size too (\(Int(size.width)) × \(Int(size.height)); it stayed 360 × 480 before)")
                self.check(panelUnder(a, panel).isEmpty, "onepassword: and sits under its anchor after resizing")
                self.c.closeExtensionPopup()
                done()
            }
        }

        // An extension can open a tab (1Password opens its app or sign-in page that way).
        step { [self] done in
            guard !fakeID.isEmpty else { return done() }
            let before = Set(c.store.state.tabs.keys)
            ask("tab", ", url: 'http://localhost:\(port)/other?from=extension'") { answer in
                self.waitUntil({ self.c.store.state.tabs.keys.contains { !before.contains($0) } }, timeout: 5) {
                    let added = self.c.store.state.tabs.keys.filter { !before.contains($0) }
                    self.check(answer.hasPrefix("tab:") && added.count == 1, "onepassword: chrome.tabs.create opens a tab in the Space (\(answer), new tabs \(added.count))")
                    if let t = self.c.store.tab(mainTab) { self.c.show(t.id, focus: false) }
                    self.waitUntil({ shownPage() === opPage }, timeout: 5) { done() }
                }
            }
        }

        // Native messaging hosts from the other browsers' folders.
        step { [self] done in
            guard sources.count == 2 else {
                check(false, "onepassword: AIRC_NATIVE_HOST_SOURCES names the runner's two host folders (\(sources.count))")
                return done()
            }
            func target(_ name: String) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: hosts.appendingPathComponent(name).path) }
            waitUntil({ target("org.airc.only_b.json") != nil }, timeout: 5) {
                let a = sources[0].appendingPathComponent("org.airc.fake_host.json").path
                self.check(target("org.airc.fake_host.json") == a, "onepassword: a host only in the first folder is linked (\(target("org.airc.fake_host.json") ?? "none"))")
                self.check(target("org.airc.both.json") == sources[0].appendingPathComponent("org.airc.both.json").path,
                           "onepassword: a host in both folders comes from the first (\(target("org.airc.both.json") ?? "none"))")
                self.check(target("org.airc.only_b.json") == sources[1].appendingPathComponent("org.airc.only_b.json").path,
                           "onepassword: a host only in the second folder is linked from it")
                self.check(target("org.airc.own.json") == nil && FileManager.default.fileExists(atPath: hosts.appendingPathComponent("org.airc.own.json").path),
                           "onepassword: a manifest already in Airc's folder stays as it was")
                self.check(!FileManager.default.fileExists(atPath: hosts.appendingPathComponent("org.airc.gone.json").path)
                           && (try? FileManager.default.destinationOfSymbolicLink(atPath: hosts.appendingPathComponent("org.airc.gone.json").path)) == nil,
                           "onepassword: Airc's link to a manifest that went away is removed")
                // The manifests' contents, now that the extension's ID is known (the links follow them).
                let origin = "chrome-extension://\(fakeID)/"
                for (folder, name, from) in [(sources[0], "org.airc.fake_host", "A"), (sources[0], "org.airc.both", "A"),
                                             (sources[1], "org.airc.both", "B"), (sources[1], "org.airc.only_b", "B"),
                                             (hosts, "org.airc.own", "own"), (sources[0], "org.airc.own", "A")] {
                    Self.writeFakeNativeHost(folder, name: name, from: from, origin: origin, scripts: self.dir)
                }
                done()
            }
        }
        for (name, from) in [("org.airc.fake_host", "A"), ("org.airc.both", "A"), ("org.airc.only_b", "B"), ("org.airc.own", "own")] {
            step { [self] done in
                guard !fakeID.isEmpty, sources.count == 2 else { return done() }
                ask("native", ", host: '\(name)'") { answer in
                    self.check(answer.hasPrefix("native:") && answer.contains("\"from\":\"\(from)\"") && answer.contains("\"ping\":\"\(name)\""),
                               "onepassword: sendNativeMessage('\(name)') reaches host \(from) (\(answer))")
                    done()
                }
            }
        }

        // Settings › Passwords › "Offer to save and fill passwords": off stops saving (Chromium's pref) and filling (the
        // app drops Chromium's list for the profile); on again restores both.
        step { [self] done in
            guard let app, let page = shownPage(), let pid = app.profiles.profileID(for: page.profile) else { return done() }
            app.setAircPasswords(false, profileID: pid)
            check(app.engine.passwordsOffered(for: page.profile) == false && PromptCenter.fillsPasswords?(page) == false && !app.aircPasswordsOn(profileID: pid),
                  "onepassword: turning Airc's passwords off stops saving and filling in the profile")
            app.setAircPasswords(true, profileID: pid)
            check(app.engine.passwordsOffered(for: page.profile) == true && PromptCenter.fillsPasswords?(page) == true && app.aircPasswordsOn(profileID: pid),
                  "onepassword: and on again restores both")
            done()
        }

        // The real 1Password extension (no account).
        step { [self] done in
            guard let folder = env["AIRC_OP_EXTENSION"], gate, let profile = shownPage()?.profile as? ChromiumProfile else {
                note("onepassword: real 1Password extension part not run (AIRC_OP_EXTENSION unset)")
                return done()
            }
            profile.core.loadUnpackedExtension(forTesting: folder) { id, error in
                DispatchQueue.main.async {
                    if let error { self.note("onepassword: 1Password: \(error)") }
                    opID = id ?? ""
                    self.check(opID == "aeblfdkhhhdcdjpifhhbdiojplfjncoa", "onepassword: 1Password loads with its Web Store ID (\(opID))")
                    // Its first-run tab, if any, opens now; give it a moment, then come back to the page.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        self.note("onepassword: 1Password listed as \(self.c.extensionActions().first { $0.id == opID }?.name ?? "?"), shown page \(shownPage()?.url?.absoluteString ?? "none")")
                        done()
                    }
                }
            }
        }
        // 1Password with no account clears its action's popup (it sets "/popup/index.html" once an account or its Mac
        // app is there), so set it back from its own page, as a signed-in 1Password has it.
        var opExtPage: ChromiumTab?
        var opVersion = "?"
        var opNoAccount = false
        func setOPPopup() {
            opExtPage?.evaluate("chrome.action.setPopup({popup: '/popup/index.html'}).then(() => 'ok'); 'set'", completion: nil)
        }
        step { [self] done in
            guard !opID.isEmpty else { return done() }
            show("chrome-extension://\(opID)/credits.html", title: "") {
                opExtPage = shownPage()
                // Its own popup before the check sets it: "" = no account and no Mac app (1Password's own rule).
                opExtPage?.evaluate("chrome.action.getPopup({}).then(p => { window.__opPopup = 'popup:' + p; }); 'asked'", completion: nil)
                poll("window.__opPopup || ''", in: opExtPage, timeout: 5) { p in
                    opNoAccount = p == "popup:"
                    setOPPopup()
                    // The fixture's version goes in the log: 1Password's in-page UI changes between releases (opcheck).
                    opExtPage?.evaluate("chrome.runtime.getManifest().version") { v in
                        opVersion = v as? String ?? "?"
                        self.note("onepassword: 1Password version \(opVersion), its popup \(p.isEmpty ? "unknown" : "'\(p.dropFirst(6))'")\(opNoAccount ? " (no account)" : "")")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done() }
                    }
                }
            }
        }
        // Its popup from the extensions list (the button's click).
        step { [self] done in
            guard !opID.isEmpty, let a = c.extensionAnchor(for: opID) else { return done() }
            let shown = c.runExtension(opID, anchor: a.view, rect: a.rect)
            waitUntil({ shownPopup()?.extensionID == opID && (shownPopup()?.panel.frame.width ?? 0) > 300 }, timeout: 8) {
                let panel = shownPopup()
                let size = panel.map { $0.panel.contentRect(forFrameRect: $0.panel.frame).size } ?? .zero
                self.check(shown && panel?.panel.isVisible == true && panel?.popup?.url.contains("/popup/index.html") == true,
                           "onepassword: 1Password's popup opens from the extensions list (\(Int(size.width)) × \(Int(size.height)))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    savePicture(panel?.popup, "1password-popup-list") { self.c.closeExtensionPopup(); done() }
                }
            }
        }
        // The owner's case: webauthn.io-style Register on a page → 1Password's "Save passkey?" card, "To save a passkey,
        // unlock 1Password first" → Unlock 1Password (a real click through DevTools input into its frame) opens its popup
        // through openPopup; then the card's ✕ hands the request on to Chromium's own passkey dialog.
        // In 1Password 8.12.46.29 (opcheck) the card needs an account: its save handler hands the request straight to
        // the browser when it has no account ("no-accounts" → fallback-requested), and its sign-in handler does the same
        // with no account in its database. Its locked in-field button (also "Unlock 1Password", same message) is off
        // without accounts too (frame config inlineDisabled = !accounts), as is its Secret Key paste guard (an account
        // flag). Accounts are off-limits here, so both are probed and clicked only if shown: with no account (its popup
        // was "") the Unlock step is a SKIP; with an account and neither shown, a "fixture changed" red (opcheck r1).
        var cardTab: ChromiumTab?
        var cardShown = false
        // A platform authenticator only: Chromium then starts no hybrid ("use a phone") discovery, whose Bluetooth adapter
        // makes macOS ask "would like to use Bluetooth" (kTCCServiceBluetoothAlways, shown by UserNotificationCenter) the
        // first time each newly signed test build runs it (release044/045 attempt 1).
        let createJS = """
        window.__pk = 'pending';
        navigator.credentials.create({publicKey: {rp: {name: 'Fixture', id: 'localhost'},
          user: {id: new Uint8Array([1, 2, 3]), name: 'fixture@example.com', displayName: 'Fixture'},
          challenge: new Uint8Array(32), pubKeyCredParams: [{type: 'public-key', alg: -7}],
          authenticatorSelection: {authenticatorAttachment: 'platform', residentKey: 'required', userVerification: 'required'},
          hints: ['client-device'], timeout: 60000}})
          .then(r => { window.__pk = r ? 'created' : 'null'; }, e => { window.__pk = 'error:' + e.name; });
        """
        // 1Password's in-page UI: shadow hosts named com-1password-<part> (closed shadow roots; the host's box is its own).
        func opHostJS(_ part: String) -> String {
            "(() => { const e = document.getElementsByTagName('com-1password-\(part)')[0]; if (!e) return ''; "
                + "const r = e.getBoundingClientRect(); if (!r.width || !r.height) return ''; return [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)].join(','); })()"
        }
        var width = 0
        func cdpClick(_ x: Int, _ y: Int, in target: ChromiumTab? = nil, _ then: @escaping () -> Void) {
            guard let tab = target ?? cardTab else { return then() }
            let base: [String: Any] = ["x": x, "y": y, "button": "left", "clickCount": 1]
            engine.devToolsCall("Input.dispatchMouseEvent", params: base.merging(["type": "mouseMoved"]) { $1 }, in: tab) { _, _ in
                engine.devToolsCall("Input.dispatchMouseEvent", params: base.merging(["type": "mousePressed"]) { $1 }, in: tab) { _, _ in
                    engine.devToolsCall("Input.dispatchMouseEvent", params: base.merging(["type": "mouseReleased"]) { $1 }, in: tab) { _, _ in
                        DispatchQueue.main.async(execute: then)
                    }
                }
            }
        }
        func checkOpenPopup(_ how: String, _ done: @escaping () -> Void) {
            waitUntil({ shownPopup()?.extensionID == opID }, timeout: 10) {
                let panel = shownPopup()
                self.check(panel?.popup?.url.contains("/popup/index.html") == true,
                           "onepassword: clicking 1Password's Unlock 1Password opens its popup (openPopup) (\(how), 1Password \(opVersion), \(panel?.popup?.url ?? "none"))")
                self.check(panelUnder(self.c.extensionPopupAnchor(for: opID), panel?.panel).isEmpty,
                           "onepassword: under the URL field \(panelUnder(self.c.extensionPopupAnchor(for: opID), panel?.panel))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    savePicture(panel?.popup, "1password-openpopup") { self.c.closeExtensionPopup(); done() }
                }
            }
        }
        step { [self] done in
            guard !opID.isEmpty else { return done() }
            if let t = c.store.tab(mainTab) { c.show(t.id, focus: false) }
            opPage?.reload()
            waitUntil({ shownPage()?.isLoading == false && shownPage()?.title == "OP page" }, timeout: 10) {
                cardTab = shownPage()
                let js = createJS + "String(innerWidth)"
                cardTab?.evaluate(js) { w in
                    width = Int(w as? String ?? "") ?? 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        cardTab?.evaluate(opHostJS("notification")) { r in
                            let rect = r as? String ?? ""
                            cardShown = !rect.isEmpty
                            self.note("onepassword: 1Password \(opVersion) passkey card \(cardShown ? "shown (\(rect))" : "not shown (no account: it hands the request to the browser)")")
                            savePicture(cardTab?.core, "1password-card") { done() }
                        }
                    }
                }
            }
        }
        step { [self] done in
            guard !opID.isEmpty, width > 0, cardShown else { return done() }
            setOPPopup()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                // "Unlock 1Password": 294 CSS px from the page's right edge, 130 down (the card at its top right).
                cdpClick(width - 294, 130) { checkOpenPopup("passkey card", done) }
            }
        }
        // No card: the probe's request went straight to Chromium's own passkey dialog (platform only: no Bluetooth step).
        step { [self] done in
            guard !opID.isEmpty, !cardShown, let tab = cardTab else { return done() }
            var dialogs = 0, stepName = ""
            waitUntil({
                let state = engine.modalDialogState(for: tab)
                dialogs = (state["dialogs"] as? [Any])?.count ?? 0
                stepName = state["webauthnStep"] as? String ?? ""
                return dialogs > 0 && !stepName.isEmpty && stepName != "kNotStarted"
            }, timeout: 10) {
                self.check(dialogs > 0 && !stepName.isEmpty && stepName != "kNotStarted" && !stepName.contains("Ble"),
                           "onepassword: with no account, 1Password \(opVersion) passes a passkey request to Chromium's own passkey dialog (step \(stepName.isEmpty ? "none" : stepName), dialogs \(dialogs))")
                engine.cancelModalDialog(in: tab)
                poll("window.__pk === 'pending' ? '' : window.__pk", in: tab, timeout: 8) { result in
                    self.check(result.hasPrefix("error:"), "onepassword: cancelling Chromium's dialog ends the page's request (\(result))")
                    done()
                }
            }
        }
        // No card: 1Password's locked in-field button ("Unlock 1Password") on a login field, the same openPopup path.
        step { [self] done in
            guard !opID.isEmpty, !cardShown else { return done() }
            show("http://localhost:\(port)/login", title: "Login page") {
                guard let page = shownPage() else { return done() }
                page.evaluate("document.getElementById('pass').focus(); document.getElementById('pass').click(); 'focused'", completion: nil)
                poll(opHostJS("button"), in: page, timeout: 6) { rect in
                    let n = rect.split(separator: ",").compactMap { Int($0) }
                    guard n.count == 4, n[2] > 0, n[3] > 0 else {
                        if opNoAccount {
                            // 8.12.46.29 with no account: the card needs one (save/sign-in handlers), the in-field
                            // button too (inline UI is off without accounts), and so does Secret Key paste protection.
                            // Accounts are off-limits here, so this step can't run; openPopup itself is covered above
                            // with the synthetic extension (artifacts/opcheck/REPORT.md).
                            self.skip("onepassword: clicking 1Password's Unlock 1Password opens its popup: 1Password \(opVersion) with no account shows neither its passkey card nor its in-field button, and the check uses no account")
                        } else {
                            self.check(false, "onepassword: fixture changed: 1Password \(opVersion) showed neither its passkey card nor its in-field Unlock 1Password button; see the check's notes and artifacts/opcheck")
                        }
                        return savePicture(page.core, "1password-no-unlock") { done() }
                    }
                    self.note("onepassword: 1Password's in-field button at \(rect) (CSS px)")
                    savePicture(page.core, "1password-field-button") {
                        setOPPopup()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            cdpClick(n[0] + n[2] / 2, n[1] + n[3] / 2, in: page) { checkOpenPopup("in-field button", done) }
                        }
                    }
                }
            }
        }
        // A fresh request each (Unlock above changed the card). On the locked card ("unlock 1Password first", the owner's
        // case) both its ✕ and its security key button hand the request to the browser: Chromium's own passkey dialog
        // (seen in every run since; 1Password's code cancels instead only on other card states). Only with a card.
        for (name, fromRight, expectDialog) in [("dismiss", 48, true), ("security-key", 84, true)] {
            step { [self] done in
                guard !opID.isEmpty, width > 0, cardShown, let tab = cardTab else { return done() }
                if let t = c.store.tab(mainTab) { c.show(t.id, focus: false) }
                tab.reload()
                self.waitUntil({ tab.isLoading == false && tab.title == "OP page" }, timeout: 10) {
                    tab.evaluate(createJS + "'started'", completion: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        savePicture(tab.core, "1password-card-before-\(name)") {
                            cdpClick(width - fromRight, 46) {
                                var dialogs = 0, stepName = ""
                                self.waitUntil({
                                    let state = engine.modalDialogState(for: tab)
                                    dialogs = (state["dialogs"] as? [Any])?.count ?? 0
                                    stepName = state["webauthnStep"] as? String ?? ""
                                    return dialogs > 0 && !stepName.isEmpty && stepName != "kNotStarted"
                                }, timeout: expectDialog ? 10 : 4) {
                                    savePicture(tab.core, "1password-card-after-\(name)") {
                                        let shown = dialogs > 0 && !stepName.isEmpty && stepName != "kNotStarted"
                                        if expectDialog {
                                            self.check(shown, "onepassword: 1Password's \(name == "dismiss" ? "✕" : "security key button") hands the request to Chromium's own passkey dialog (step \(stepName.isEmpty ? "none" : stepName), dialogs \(dialogs))")
                                            engine.cancelModalDialog(in: tab)
                                        }
                                        poll("window.__pk === 'pending' ? '' : window.__pk", in: tab, timeout: 8) { result in
                                            if expectDialog {
                                                self.check(result.hasPrefix("error:"), "onepassword: cancelling Chromium's dialog ends the page's request (\(result))")
                                            } else {
                                                self.check(!shown && result == "null", "onepassword: 1Password's ✕ cancels the request (page gets \(result), browser dialog \(shown))")
                                            }
                                            done()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // The offer, once: 1Password is on in the profile and Airc's passwords are on.
        step { [self] done in
            guard !opID.isEmpty, let app else { return done() }
            app.settings.values.passwordManagerOffered.removeAll { $0 == c.currentProfileID }
            PasswordManagerOffer.consider(in: c, actions: c.extensionActions(), forCheck: true)
            let card = PasswordManagerOffer.card(in: c)
            check(card != nil && card?.window === c.window, "onepassword: with 1Password on, a card offers to let it handle passwords")
            if let card { saveView(card, "offer-card") }
            check(c.window.isKeyWindow || !NSApp.isActive, "onepassword: the card leaves the window key (it takes no focus)")
            c.window.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.clickAnchor("pmoffer.use", in: self.c.window.contentView!) {
                let pid = self.c.currentProfileID
                self.check(PasswordManagerOffer.card(in: self.c) == nil && !app.aircPasswordsOn(profileID: pid)
                           && app.settings.values.passwordManagerOffered.contains(pid),
                           "onepassword: Use 1Password turns Airc's saving and filling off there, and the card doesn't come back")
                PasswordManagerOffer.consider(in: self.c, actions: self.c.extensionActions(), forCheck: true)
                self.check(PasswordManagerOffer.card(in: self.c) == nil, "onepassword: asked once per profile")
                app.setAircPasswords(true, profileID: pid)
                done()
            } }
        }

        fillOnLoad("1Password installed")

        // Proton Pass (no account): its 600 × 430 popup in full, and its in-page dropdown on a login form.
        step { [self] done in
            guard let folder = env["AIRC_PP_EXTENSION"], gate, let profile = shownPage()?.profile as? ChromiumProfile else {
                note("onepassword: Proton Pass part not run (AIRC_PP_EXTENSION unset)"); return done()
            }
            profile.core.loadUnpackedExtension(forTesting: folder) { id, error in
                DispatchQueue.main.async {
                    if let error { self.note("onepassword: Proton Pass: \(error)") }
                    ppID = id ?? ""
                    self.check(ppID == "ghmbeldphafepmbegfdlkpapadhbakde", "onepassword: Proton Pass loads with its Web Store ID (\(ppID))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { done() }
                }
            }
        }
        step { [self] done in
            guard !ppID.isEmpty else { return done() }
            show("http://localhost:\(port)/login", title: "Login page") { done() }
        }
        step { [self] done in
            guard !ppID.isEmpty, let a = c.extensionAnchor(for: ppID) else { return done() }
            let shown = c.runExtension(ppID, anchor: a.view, rect: a.rect)
            waitUntil({ (shownPopup()?.panel.contentRect(forFrameRect: shownPopup()!.panel.frame).width ?? 0) >= 590 }, timeout: 8) {
                let panel = shownPopup()
                let size = panel.map { $0.panel.contentRect(forFrameRect: $0.panel.frame).size } ?? .zero
                self.check(shown && size == NSSize(width: 600, height: 430), "onepassword: Proton Pass's popup shows whole, 600 × 430 (\(Int(size.width)) × \(Int(size.height)))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    savePicture(panel?.popup, "protonpass-popup-\(NSApp.effectiveAppearance.name.rawValue.contains("Dark") ? "dark" : "light")") {
                        self.c.closeExtensionPopup(); done()
                    }
                }
            }
        }
        step { [self] done in
            guard !ppID.isEmpty, let page = shownPage() else { return done() }
            page.evaluate("document.getElementById('user').focus(); document.getElementById('user').click(); 'focused'", completion: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                page.evaluate("String(document.querySelectorAll('protonpass-root, [data-protonpass-role], iframe').length)") { n in
                    self.note("onepassword: Proton Pass elements on the login page after focus: \(n ?? "?")")
                    savePicture(page.core, "protonpass-login-dropdown") { done() }
                }
            }
        }

        fillOnLoad("1Password and Proton Pass installed")
        run { server?.stop() }
        #else
        check(false, "onepassword: requires the Chromium engine")
        #endif
    }

    /// The synthetic password-manager extension: an action with a popup; a service worker that calls
    /// chrome.action.openPopup(), probes its access to the active tab and calls native hosts; a content script on
    /// localhost pages relaying the page's postMessage requests and writing answers as `data-op-<op>` attributes.
    static func writeOnePasswordFake(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [
            "manifest.json": """
            {"manifest_version": 3, "name": "OP Fake", "version": "1",
             "action": {"default_title": "OP Fake", "default_popup": "popup.html"},
             "background": {"service_worker": "sw.js"},
             "permissions": ["nativeMessaging", "activeTab"],
             "content_scripts": [{"matches": ["http://localhost/*"], "js": ["cs.js"], "run_at": "document_start"}]}
            """,
            "popup.html": "<!doctype html><meta charset=utf-8><title>OP Fake popup</title><body style=\"margin:0;width:600px;height:430px;"
                + "font:14px -apple-system;display:flex;align-items:center;justify-content:center;background:#fffaf2\">Unlock OP Fake</body>",
            "sw.js": """
            // Without a tab permission the active tab's URL is hidden: "url:none" means no activeTab grant.
            const probe = () => chrome.tabs.query({active: true, lastFocusedWindow: true}).then(t => 'url:' + (t[0] && t[0].url || 'none'));
            chrome.runtime.onMessage.addListener((m, sender, reply) => {
              if (m.op === 'open') { chrome.action.openPopup().then(() => reply('ok'), e => reply('error: ' + e.message)); return true; }
              if (m.op === 'probe') {
                new Promise(r => setTimeout(r, 2500)).then(() => chrome.action.openPopup()).then(() => new Promise(r => setTimeout(r, 300)))
                  .then(probe).then(reply, e => reply('error: ' + e.message));
                return true;
              }
              if (m.op === 'tab') { chrome.tabs.create({url: m.url}).then(t => reply('tab:' + (t && t.id)), e => reply('error: ' + e.message)); return true; }
              if (m.op === 'probe-now') { probe().then(reply, e => reply('error: ' + e.message)); return true; }
              if (m.op === 'native') {
                chrome.runtime.sendNativeMessage(m.host, {ping: m.host}).then(r => reply('native:' + JSON.stringify(r)), e => reply('error: ' + e.message));
                return true;
              }
            });
            """,
            "cs.js": """
            document.documentElement.setAttribute('data-opfake', 'ready');
            window.addEventListener('message', e => {
              if (e.source !== window || !e.data || !e.data.opfake) return;
              const m = e.data.opfake;
              chrome.runtime.sendMessage(m, r => {
                const answer = r === undefined ? 'error: ' + (chrome.runtime.lastError && chrome.runtime.lastError.message) : String(r);
                document.documentElement.setAttribute('data-op-' + m.op, answer);
              });
            });
            """,
        ]
        for (name, text) in files { try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    }

    /// A fake native messaging host: `<name>.json` in `folder` naming a script that answers one message with
    /// {"from": <from>, "ping": <the message's ping>}.
    static func writeFakeNativeHost(_ folder: URL, name: String, from: String, origin: String, scripts: URL) {
        let script = scripts.appendingPathComponent("fake-host-\(from).py")
        let python = """
        #!/usr/bin/python3
        import json, struct, sys
        size = struct.unpack('=I', sys.stdin.buffer.read(4))[0]
        message = json.loads(sys.stdin.buffer.read(size))
        out = json.dumps({'from': '\(from)', 'ping': message.get('ping')}, separators=(',', ':')).encode()
        sys.stdout.buffer.write(struct.pack('=I', len(out)) + out)
        sys.stdout.buffer.flush()
        """
        try? python.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manifest = """
        {"name": "\(name)", "description": "Airc check fake host \(from)", "path": "\(script.path)", "type": "stdio",
         "allowed_origins": ["\(origin)"]}
        """
        // Write through the file (a link in Airc's folder points at it): never replace it.
        let path = folder.appendingPathComponent(name + ".json").path
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.truncateFile(atOffset: 0)
            handle.write(manifest.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? manifest.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}
#endif
