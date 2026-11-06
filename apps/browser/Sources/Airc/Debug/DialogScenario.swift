// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit

#if canImport(AircCore)
/// `--script dialogs` (Chromium; owner P0, 2026-11-05: Google sign-in aborted the app at its passkey dialog). The
/// engine's web-modal dialogs in the app's own window, from pages on a loopback server, read through the engine's
/// native-state hook (`--airc-test=modalDialogs`, on its scratch, mock-keychain test gate; build-app.sh passes it).
/// Each dialog must belong to the window's registered Views parent, lie over our page, hide with its tab and come back
/// with it, and its Cancel must reach the page. An abort leaves no log, which build-app.sh reports as a FAIL.
///   - WebAuthn `navigator.credentials.get`: platform only, then platform + hybrid (Google's email step asks for a
///     passkey this way; hybrid looks for a phone over Bluetooth);
///   - HTTP Basic auth, cancelled; then a tab closed while its auth dialog is still up (the teardown that crashed);
///   - beforeunload on a navigation: Cancel stays on the page;
///   - ⌘W on that page: the tab stays while the page asks, Cancel changes nothing, and a handler that lets the close
///     through takes the tab out of the sidebar only once the page has closed.
extension SnapshotRunner {
    func dialogsScenario() {
        guard let engine = app?.engine as? ChromiumEngine else { return note("dialogs: Chromium only") }
        var base = ""
        var server: LocalPageServer?
        var tabID = ""
        var dialogNumber = 0
        let page = { self.c.engineTab(for: tabID) }
        func state() -> [String: Any] { page().map { engine.modalDialogState(for: $0) } ?? [:] }
        func dialogs() -> [[String: Any]] { state()["dialogs"] as? [[String: Any]] ?? [] }
        func window(_ number: Int) -> NSWindow? { NSApp.windows.first { $0.windowNumber == number } }

        step { [self] done in
            func webauthn(_ transports: String) -> String {
                "<title>webauthn</title><p>Passkey request</p><script>navigator.credentials.get({publicKey:{challenge:new Uint8Array(32).fill(7),"
                + "rpId:'localhost',timeout:60000,allowCredentials:[{type:'public-key',id:new Uint8Array(32).fill(9),transports:\(transports)}]}})"
                + ".then(function(){document.title='resolved'},function(e){document.title='rejected '+e.name});</script>"
            }
            server = LocalPageServer(responses: [
                "/platform": .init(body: webauthn("['internal']")),
                "/hybrid": .init(body: webauthn("['internal','hybrid']")),
                "/auth": .init(status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"Synthetic Airc dialog\""],
                               body: "<title>unauthorized</title><p>Not signed in</p>"),
                "/leave": .init(body: "<title>leave</title><p>Unsaved changes</p>"
                                + "<script>onbeforeunload=function(e){e.preventDefault();e.returnValue=''}</script>"),
                "/away": .init(body: "<title>away</title><p>Left</p>"),
            ])
            guard let server else { check(false, "dialogs: the loopback server starts"); return done() }
            server.start { port in
                guard let port else { self.check(false, "dialogs: the loopback server starts"); return done() }
                // WebAuthn needs a domain for its relying party; localhost is a secure context like 127.0.0.1.
                base = "http://localhost:\(port)"
                done()
            }
        }

        func openPage(_ path: String) {
            run { [self] in
                guard !base.isEmpty, let t = try? c.store.openTab(url: base + path, inSpace: c.currentSpaceID, title: path) else { return }
                tabID = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
        }

        /// The dialog `name` comes up, owned by our window's registered parent and lying over our page card.
        func expectDialog(_ name: String) {
            step { [self] done in
                waitUntil({ !dialogs().isEmpty }, timeout: 10) {
                    let s = state(), d = dialogs().first ?? [:]
                    dialogNumber = (d["windowNumber"] as? NSNumber)?.intValue ?? 0
                    let w = window(dialogNumber)
                    let pageRect = self.c.window.convertToScreen(self.c.card.convert(self.c.card.bounds, to: nil))
                    let owned = s["registeredHost"] as? Bool == true && s["hostViewInAppWindow"] as? Bool == true
                        && d["registeredParentMatchesHost"] as? Bool == true && d["childModal"] as? Bool == true
                    let shown = d["wantsVisible"] as? Bool == true
                    // The dialog's window hangs off the registered parent, a child window of ours (any depth counts).
                    var chain: [NSWindow] = []
                    while let p = (chain.last ?? w)?.parent, chain.count < 4 { chain.append(p) }
                    let overPage = w.map { pageRect.intersects($0.frame) } ?? false
                    // With the screen locked, or our window on another Space (the owner in a full-screen app), AppKit
                    // defers showing the dialog and linking it as a child window (seen 2026-11-05; P0-DIALOGS.md).
                    let linked = chain.contains { $0 === self.c.window }
                    let why = Self.screenLocked ? "the screen is locked" : self.c.window.isOnActiveSpace ? nil : "our window isn't on the active Space"
                    let inWindow = (linked || why != nil) && overPage
                    if let why, !linked {
                        // Off the active Space (or locked) the dialog correctly waits to show (2daa1a8): only check it's ours.
                        self.skip("dialogs: \(name) shows in our window: \(why)")
                        self.check(owned, "dialogs: \(name) is created for our window while it can't show (\(why))")
                        return done()
                    }
                    self.check(owned && shown && inWindow,
                          "dialogs: \(name) shows in our window (DCHECKs \(s["dchecks"] ?? "?"), owned \(owned), wants visible \(shown), "
                          + "on screen \(d["widgetVisible"] ?? "?"), over the page \(inWindow), frame \(d["frame"] ?? "-")"
                          + (inWindow ? ")" : "; window \(w == nil ? "not found" : "found"), parents "
                             + chain.map { "\(type(of: $0))#\($0.windowNumber)" }.joined(separator: " < ")
                             + ", ours #\(self.c.window.windowNumber), page \(NSStringFromRect(pageRect)), over it \(overPage), "
                             + "on the active Space \(self.c.window.isOnActiveSpace))"))
                    done()
                }
            }
        }

        /// Another tab hides the dialog; coming back shows the same one again.
        func expectFollowsTab(_ name: String) {
            var other = ""
            run { [self] in
                guard let t = try? c.store.openTab(url: "about:blank", inSpace: c.currentSpaceID, title: "Other") else { return }
                other = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            step { [self] done in
                waitUntil({ window(dialogNumber)?.isVisible != true }, timeout: 3) {
                    let hidden = window(dialogNumber)?.isVisible != true
                    self.c.show(tabID, focus: false)
                    self.waitUntil({ window(dialogNumber)?.isVisible == true || dialogs().first?["wantsVisible"] as? Bool == true }, timeout: 3) {
                        let back = (dialogs().first?["windowNumber"] as? NSNumber)?.intValue == dialogNumber
                        self.check(hidden && back, "dialogs: \(name) hides on another tab (\(hidden)) and the same one comes back (\(back))")
                        if !other.isEmpty { self.c.closeTab(other) }
                        done()
                    }
                }
            }
        }

        func cancel(_ name: String) {
            step { [self] done in
                let ok = page().map { engine.cancelModalDialog(in: $0) } ?? false
                let cancelled = dialogNumber
                waitUntil({ dialogs().isEmpty }, timeout: 4) {
                    let left = dialogs().map { d in
                        let n = (d["windowNumber"] as? NSNumber)?.intValue ?? 0
                        return "\(n == cancelled ? "the same" : "another") dialog #\(n), wants visible \(d["wantsVisible"] ?? "?"), on screen \(d["widgetVisible"] ?? "?")"
                    }
                    self.check(ok && left.isEmpty, "dialogs: \(name): Cancel closes it (handler found \(ok))"
                               + (left.isEmpty ? "" : "; left: " + left.joined(separator: ", ")))
                    done()
                }
            }
        }

        // WebAuthn, platform only, then platform + hybrid. Hybrid needs Bluetooth: an ad-hoc signed test build asks
        // for it with a system prompt on the build Mac's screen (again after every rebuild) and the request waits for
        // the answer, so that case is opt-in (AIRC_DIALOGS_HYBRID=1, someone at the Mac to answer the prompt).
        let hybrid = ProcessInfo.processInfo.environment["AIRC_DIALOGS_HYBRID"] == "1"
        if !hybrid {
            run { [self] in skip("dialogs: passkey (platform + hybrid): asks for Bluetooth with a system prompt; AIRC_DIALOGS_HYBRID=1 runs it") }
        }
        for (path, name) in [("/platform", "passkey (platform)"), ("/hybrid", "passkey (platform + hybrid)")] where path != "/hybrid" || hybrid {
            openPage(path)
            expectDialog(name)
            if path == "/hybrid" { expectFollowsTab(name) }
            cancel(name)
            step { [self] done in
                waitUntil({ page()?.title.hasPrefix("rejected") == true }, timeout: 3) {
                    self.check(page()?.title == "rejected NotAllowedError", "dialogs: \(name): the page's request is rejected (\(page()?.title ?? "-"))")
                    done()
                }
            }
        }

        // HTTP Basic auth: Cancel shows the server's 401 page.
        openPage("/auth")
        expectDialog("HTTP auth")
        cancel("HTTP auth")
        step { [self] done in
            waitUntil({ page()?.title == "unauthorized" }, timeout: 3) {
                self.check(page()?.title == "unauthorized", "dialogs: HTTP auth: after Cancel the page shows the 401 response (\(page()?.title ?? "-"))")
                done()
            }
        }
        // …and a tab closed while its auth dialog is up: the dialog goes with it and the app keeps running.
        openPage("/auth")
        expectDialog("HTTP auth (to close)")
        run { [self] in c.closeTab(tabID) }
        step { [self] done in
            // Closed is enough: a closed Views window can stay in NSApp.windows until it's released; still on screen isn't.
            waitUntil({ window(dialogNumber)?.isVisible != true && dialogs().isEmpty }, timeout: 4) {
                let w = window(dialogNumber)
                self.check(w?.isVisible != true, "dialogs: closing a tab with its auth dialog up closes the dialog, no crash ("
                           + (w == nil ? "window gone" : "window \(w!.isVisible ? "still on screen" : "closed"), not yet released") + ")")
                done()
            }
        }

        // beforeunload on a navigation (the page needs a user activation first: Chromium asks only pages the user
        // touched). Scripted runs never activate the app, and a page in an inactive window doesn't take a click (its
        // first click only activates, as in Chrome), so the activation comes from a DevTools user gesture.
        openPage("/leave")
        waitForPage()
        step { [self] done in
            guard let p = page() else { return done() }
            engine.devToolsCall("Runtime.evaluate", params: ["expression": "navigator.userActivation.isActive", "userGesture": true,
                                                             "returnByValue": true], in: p) { reply, error in
                let active = ((reply?["result"] as? [String: Any])?["value"] as? Bool) == true
                self.note("dialogs: leave site: user activation from a DevTools gesture \(active)\(error.map { " (\($0))" } ?? "")")
                done()
            }
        }
        run { page()?.load(URL(string: base + "/away")!) }
        expectDialog("leave site (beforeunload)")
        cancel("leave site (beforeunload)")
        wait(0.8)
        run { [self] in
            check(page()?.url?.path == "/leave", "dialogs: leave site: Cancel stays on the page (\(page()?.url?.path ?? "-"))")
        }

        // ⌘W on the same page (it still asks): the tab stays in the sidebar, shown, while the page asks, and Cancel
        // leaves the tab and its page as they were.
        var tabs = 0, undos = 0
        run { [self] in tabs = c.store.todayTabs(ofSpace: c.currentSpaceID).count; undos = c.store.undoStack.count }
        commandW { self.c.closingTabs.contains(tabID) }
        expectDialog("close tab (beforeunload)")
        run { [self] in
            let kept = c.store.tab(tabID) != nil, shown = c.shownTabID == tabID, open = page().map { !$0.isClosed } ?? false
            check(kept && shown && open, "dialogs: ⌘W on a page that asks: the tab stays while it asks (in the sidebar \(kept), "
                  + "shown \(shown), page open \(open))")
        }
        cancel("close tab (beforeunload)")
        wait(0.8)
        run { [self] in
            let kept = c.store.tab(tabID) != nil, shown = c.shownTabID == tabID, open = page().map { !$0.isClosed } ?? false
            let same = c.store.todayTabs(ofSpace: c.currentSpaceID).count == tabs && page()?.url?.path == "/leave"
            check(kept && shown && open && same && c.store.undoStack.count == undos,
                  "dialogs: ⌘W, then Cancel: nothing changes (in the sidebar \(kept), shown \(shown), page open \(open), "
                  + "same tabs and page \(same), undo entries \(undos) → \(c.store.undoStack.count))")
        }
        // A handler that lets the close through: Chromium runs it, then closes the page, and only then does the tab
        // leave the sidebar, as an undoable Close Tab. (It also means quitting won't ask and wait.)
        step { [self] done in
            guard let p = page() else { return done() }
            p.evaluate("onbeforeunload=function(){};1") { _ in done() }
        }
        commandW { self.c.store.tab(tabID) == nil }
        step { [self] done in
            waitUntil({ self.c.store.tab(tabID) == nil }, timeout: 4) {
                let gone = self.c.store.tab(tabID) == nil && page() == nil && self.c.shownTabID != tabID
                let count = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).count
                self.check(gone && count == tabs - 1 && self.c.store.undoLabel == "Close Tab",
                           "dialogs: ⌘W on a page whose handler lets it close: the tab leaves the sidebar once the page has closed "
                           + "(gone \(gone), tabs \(tabs) → \(count), undo \(self.c.store.undoLabel ?? "-"))")
                done()
            }
        }
        clearTodayWaitsForLeaveSite(openPage: openPage, expectDialog: expectDialog, cancel: cancel, page: page,
                                    tabID: { tabID }, setTab: { tabID = $0 })
        run { server?.stop() }
    }

    /// Clear Today with a page that asks "Leave site?" among its tabs (like ⌘W): the plain tab goes at once; the asking
    /// one is shown with its question, and Stay keeps it (and stops there); with a handler that lets it go, it's
    /// archived once its page has closed and the tab the person was on comes back.
    private func clearTodayWaitsForLeaveSite(openPage: (String) -> Void, expectDialog: (String) -> Void, cancel: (String) -> Void,
                                             page: @escaping () -> EngineTab?, tabID: @escaping () -> String,
                                             setTab: @escaping (String) -> Void) {
        guard let engine = app?.engine as? ChromiumEngine else { return }
        var asking = "", plain = "", kept = ""
        openPage("/leave")
        waitForPage()
        step { [self] done in
            asking = tabID()
            guard let p = page() else { return done() }
            engine.devToolsCall("Runtime.evaluate", params: ["expression": "navigator.userActivation.isActive", "userGesture": true,
                                                             "returnByValue": true], in: p) { _, _ in done() }
        }
        openPage("/away")
        run { plain = tabID() }
        openPage("/away")
        run { kept = tabID() }
        wait(0.8)
        run { [self] in c.clearToday() }
        // The asking tab comes to the front with its question (the dialogs' checks follow that page from here).
        step { [self] done in
            waitUntil({ self.c.shownTabID == asking }, timeout: 3) { setTab(asking); done() }
        }
        expectDialog("clear today (beforeunload)")
        run { [self] in
            let plainGone = c.store.tab(plain) == nil
            let askingStays = c.store.tab(asking) != nil && c.shownTabID == asking && c.archiveQueue?.current == asking
            check(plainGone && askingStays && c.store.tab(kept) != nil,
                  "dialogs: Clear Today: a plain tab goes at once (\(plainGone)), the asking one is shown with its question (\(askingStays)), "
                  + "the shown tab stays (\(c.store.tab(kept) != nil))")
        }
        cancel("clear today (beforeunload)")
        step { [self] done in
            waitUntil({ self.c.archiveQueue == nil }, timeout: 3) {
                let stayed = self.c.store.tab(asking) != nil && page().map { !$0.isClosed } ?? false
                self.check(stayed && self.c.archiveQueue == nil,
                           "dialogs: Clear Today, then Stay: the tab and its page stay, and Clear stops (queue \(self.c.archiveQueue == nil ? "done" : "still waiting"))")
                done()
            }
        }
        // A handler that lets it go: Clear Today again archives it once the page has closed.
        step { [self] done in
            guard let p = c.engineTab(for: asking) else { return done() }
            p.evaluate("onbeforeunload=function(){};1") { _ in done() }
        }
        run { [self] in
            c.show(kept, focus: false)
            c.clearToday()
            note("dialogs: Clear Today again: waiting on it \(c.archiveQueue?.current == asking), closing \(c.closingTabs.contains(asking)), "
                 + "page closed \(c.engineTab(for: asking)?.isClosed.description ?? "no page"), in Today \(c.store.todayTabs(ofSpace: c.currentSpaceID).contains { $0.id == asking })")
        }
        step { [self] done in
            waitUntil({ self.c.store.tab(asking) == nil && self.c.archiveQueue == nil }, timeout: 5) {
                let archived = self.c.store.archivedEntries.first { $0.tab.id == asking }
                self.check(self.c.store.tab(asking) == nil && archived?.reason == .clear && self.c.shownTabID == kept
                           && self.c.store.undoLabel == "Clear Today",
                           "dialogs: Clear Today with a handler that lets the page go: archived once it has closed (\(archived?.reason.rawValue ?? "not archived"), "
                           + "in the sidebar \(self.c.store.tab(asking) != nil), page \(self.c.engineTab(for: asking).map { $0.isClosed ? "closed" : "open" } ?? "none"), queue \(self.c.archiveQueue?.current == asking)), "
                           + "back on the shown tab (\(self.c.shownTabID == kept)), undo \(self.c.store.undoLabel ?? "-")")
                done()
            }
        }
    }

    /// ⌘W through the window, as a person presses it; `arrived` tells that the app acted on it. A window that was never
    /// key can drop a posted key (scripted runs never activate the app); then the same key event goes to the main menu,
    /// which is where the window sends it.
    private func commandW(arrived: @escaping () -> Bool) {
        step { [self] done in
            postKey("w", keyCode: 13, modifiers: .command)
            waitUntil(arrived, timeout: 2) {
                if !arrived(), let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.c.window.windowNumber,
                                            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13) {
                    let handled = NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
                    self.note("dialogs: the posted ⌘W didn't arrive (window key \(self.c.window.isKeyWindow)); "
                              + "sent it to the main menu (handled \(handled))")
                }
                done()
            }
        }
    }
}
#endif
#endif
