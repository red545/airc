// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// passkeyquit (wkpasskeyquit): a page's pending passkey autofill request (`navigator.credentials.get` with
/// `mediation: 'conditional'`) and the sheet WebKit attached by itself on appleid.apple.com's sign-in never hold up
/// closing the tab, going to another page, closing the window or quitting, on both engines, and no sheet comes by itself.
/// Synthetic: one loopback fixture on localhost (a valid WebAuthn RP ID; nothing is ever created or signed in). The
/// last step quits the app with the pending request open; the runner (scripts/tests/passkeyquit/run-checks.sh)
/// measures the exit from outside and adds that assertion (≤ 3 s).
///   AIRC_PASSKEYQUIT_QUIT=hold (default): ⌘Q, held. With AIRC_REAL_KEYS=1 in a dedicated session it is the UI
///     driver's real ⌘Q key-down; the driver can't hold a key, so "still held at 0.7 s" is stood in (as the shortcuts
///     check does). The quit itself is the product's (KeyMonitor.quit → NSApp.terminate).
///   AIRC_PASSKEYQUIT_QUIT=menu: Airc › Quit Airc from the main menu (performActionForItem).
///   AIRC_PASSKEYQUIT_QUIT=ae: the quit Apple Event to our own process, as the Dock's Quit and a logout send it.
///   AIRC_PASSKEYQUIT_REAL=1: the real appleid.apple.com sign-in page too (signed out, nothing typed). On WebKit the
///     tab, navigation, window and quit cases then use it: its SSO sheet (WebKitPasskeyGuard.swift) is what held quits.
///   AIRC_TEST_PASSKEY_GUARD (WebKit, WebKitPasskeyGuard.mode): off = the before arm (nothing of the fix); sso = the
///     SSO sheet allowed, so the sheet-ending path is what's proved; pass = an entitled build's request tracking.
/// Tab closing and the window are real keys (⌘W, ⇧⌘W through the driver) in real runs, otherwise the same commands.
extension SnapshotRunner {
    func passkeyQuitScenario() { PasskeyQuitCheck(runner: self).start() }
}

final class PasskeyQuitCheck {
    let r: SnapshotRunner
    let engine: String
    let env = ProcessInfo.processInfo.environment
    var server: LocalPageServer?
    var port: UInt16 = 0
    var sheets: [String] = []
    var observer: NSObjectProtocol?

    init(runner: SnapshotRunner) {
        r = runner
        engine = runner.app?.engine is WebKitEngine ? "WebKit" : "Chromium"
    }

    var real: Bool { env["AIRC_REAL_KEYS"] == "1" && env["AIRC_UI_DEDICATED_SESSION"] == "1" && UIDriverClient.available }
    var mode: String { real ? "[real]" : "[posted]" }
    var webkit: Bool { engine == "WebKit" }
    /// The WebKit guard's mode ("hold": conditional requests stay in the page; "pass": they go to WebKit).
    var guardMode: String { webkit ? WebKitPasskeyGuard.mode : "-" }
    /// The arms that keep the sheet (off: before wkpasskeyquit; sso: Sign In With Apple's SSO extension allowed, to prove
    /// the ending path): evidence, so the "no sheet by itself" lines are notes there.
    var passArm: Bool { webkit && (guardMode == "sso" || guardMode == "off") }
    /// WebKit with AIRC_PASSKEYQUIT_REAL=1: closing, leaving and quitting use the real appleid.apple.com page, where
    /// WebKit's SSO sheet comes by itself.
    var appleCases: Bool { webkit && env["AIRC_PASSKEYQUIT_REAL"] == "1" }
    var app: AppDelegate? { r.app }
    var c: WindowController? { app?.controller }
    func check(_ ok: Bool, _ s: String) { r.check(ok, "passkeyquit \(engine): " + s) }
    func note(_ s: String) { r.note("passkeyquit \(engine): " + s) }
    var base: String { "http://localhost:\(port)" }

    // MARK: Fixture

    /// Asks for passkey autofill at load (whether or not the browser says it's available, as some sites do) and keeps
    /// what happened in `window.__pk`. The username field is never focused.
    static let page = """
    <!doctype html><title>Passkey fixture</title>
    <style>body{font:16px -apple-system;margin:16px}input{font-size:16px;padding:6px}</style>
    <h1>Sign in</h1><input id=user autocomplete="username webauthn" placeholder="Email or phone">
    <script>
    window.__pk = { state: 'starting', available: '-' };
    (async function () {
      try { window.__pk.available = String(await PublicKeyCredential.isConditionalMediationAvailable()); }
      catch (e) { window.__pk.available = 'error ' + e.name; }
      var ctl = new AbortController();
      window.__pkAbort = ctl;
      window.__pk.state = 'pending';
      try {
        await navigator.credentials.get({ mediation: 'conditional', signal: ctl.signal, publicKey: {
          challenge: crypto.getRandomValues(new Uint8Array(32)), rpId: location.hostname, allowCredentials: [],
          userVerification: 'preferred', timeout: 600000 } });
        window.__pk.state = 'resolved';
      } catch (e) { window.__pk.state = 'rejected ' + e.name; }
    })();
    </script>
    """

    func startServer(_ done: @escaping () -> Void) {
        server = LocalPageServer(pages: [:])
        server?.requestHandler = { request in
            switch request.path {
            case "/cond": return LocalPageServer.Page(body: Self.page)
            case "/other": return LocalPageServer.Page(body: "<!doctype html><title>Another page</title><h1>Another page</h1>")
            default: return nil
            }
        }
        server?.start { [self] p in
            port = p ?? 0
            check(port != 0, "the loopback fixture runs")
            done()
        }
    }

    // MARK: Helpers

    static let state = "JSON.stringify({pk: window.__pk || null, guard: window.__aircPasskeyGuard || null})"

    /// A system sheet on any of Airc's windows now (class names), or "none".
    func attachedSheets() -> String {
        let found = NSApp.windows.compactMap { w -> String? in
            guard let s = w.attachedSheet else { return nil }
            return "\(type(of: w)) \"\(w.title.prefix(30))\": \(WebKitPasskeyGuard.describe(s).prefix(8).joined(separator: ","))"
        }
        return found.isEmpty ? "none" : found.joined(separator: "; ")
    }

    func evaluate(_ page: EngineTab?, _ done: @escaping (String) -> Void) {
        guard let page else { return done("no page") }
        page.evaluate(Self.state) { v in done((v as? String) ?? "\(v.map { "\($0)" } ?? "nil")") }
    }

    /// Opens the fixture in `w` (default: the main window), waits for its request to be pending, then `then(tabID)`.
    func openPending(_ tag: String, in w: (() -> WindowController?)? = nil, then: @escaping (String?) -> Void) {
        guard let w = (w ?? { self.c })(), let t = try? w.store.openTab(url: "\(base)/cond?c=\(tag)", inSpace: w.currentSpaceID) else {
            check(false, "\(tag): the fixture page opens"); return then(nil)
        }
        w.show(t.id)
        var last = ""
        let deadline = Date().addingTimeInterval(15)
        func poll() {
            evaluate(w.engineTab(for: t.id)) { s in
                last = s
                // WebKit without the passkey capability answers at once itself: unavailable, NotAllowedError, no UI.
                let answered = self.webkit && !WebKitPasskeyNotice.entitled && s.contains("\"available\":\"false\"")
                    && s.contains("\"state\":\"rejected NotAllowedError\"")
                if s.contains("\"state\":\"pending\"") || answered || Date() > deadline {
                    let ok = s.contains("\"state\":\"pending\"") || answered
                    self.check(ok, "\(tag): the page's passkey autofill request is pending\(self.webkit ? " (or, WebKit without the capability, answered at once)" : "") (\(s.prefix(260)))")
                    return then(ok ? t.id : nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
            }
        }
        poll()
        _ = last
    }

    /// A PNG of one of our windows (a sheet) into the run's folder.
    func shot(_ w: NSWindow, _ name: String) {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let image = unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(w.windowNumber), (1 << 3) | (1 << 0))?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let url = r.dir.appendingPathComponent("\(name).png")
        try? png.write(to: url)
        note("sheet picture \(url.lastPathComponent): \(image.width)×\(image.height)")
    }

    /// The page a case closes, leaves or quits with: the fixture, or (appleCases) the real appleid.apple.com sign-in.
    func openCase(_ tag: String, in w: (() -> WindowController?)? = nil, then: @escaping (String?) -> Void) {
        appleCases ? openAppleID(tag, in: w, then: then) : openPending(tag, in: w, then: then)
    }

    /// appleid.apple.com's sign-in in `w`, loaded, and up to 8 s for WebKit's SSO sheet (it may not come).
    func openAppleID(_ tag: String, in w: (() -> WindowController?)? = nil, then: @escaping (String?) -> Void) {
        guard let w = (w ?? { self.c })(), let t = try? w.store.openTab(url: "https://appleid.apple.com/sign-in", inSpace: w.currentSpaceID) else {
            check(false, "\(tag): appleid.apple.com opens"); return then(nil)
        }
        w.show(t.id)
        let begun = sheets.count
        r.waitUntil({ w.engineTab(for: t.id).map { !$0.isLoading && $0.url?.host != nil } == true }, timeout: 30) {
            self.r.waitUntil({ w.window.attachedSheet != nil || self.sheets.count > begun }, timeout: 8) {
                let page = w.engineTab(for: t.id)
                self.check(page?.url?.host?.hasSuffix("apple.com") == true, "\(tag): appleid.apple.com loads (\(page?.url?.host ?? "-"), "
                           + "sheet on its window \(w.window.attachedSheet.map { WebKitPasskeyGuard.describe($0).prefix(3).joined(separator: ",") } ?? "none"))")
                then(t.id)
            }
        }
    }

    func key(_ combo: String, _ done: @escaping (Bool, String) -> Void) {
        UIDriverClient.run(["--key", combo, "--pid", String(ProcessInfo.processInfo.processIdentifier)], done)
    }

    // MARK: The run

    func start() {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main) {
            [weak self] n in
            guard let parent = n.object as? NSWindow else { return }
            DispatchQueue.main.async {
                guard let self, let sheet = parent.attachedSheet else { return }
                let what = "\(type(of: parent)) \"\(parent.title.prefix(30))\": \(WebKitPasskeyGuard.describe(sheet).joined(separator: ","))"
                self.sheets.append(what)
                self.note("sheet began on \(what); system passkey sheet \(WebKitPasskeyGuard.isSystemPasskeySheet(sheet))")
                // What it shows (our own window: no Screen Recording needed), after it had time to draw.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak sheet] in
                    guard let sheet, sheet.isVisible else { return }
                    self.shot(sheet, "sheet-\(self.sheets.count)")
                }
            }
        }
        r.run { [self] in
            note("\(mode), guard \(guardMode), entitled \(WebKitPasskeyNotice.entitled), quit \(env["AIRC_PASSKEYQUIT_QUIT"] ?? "hold"), "
                 + "keyboard \(UIDriverClient.layoutName)")
        }
        if real { r.activateForRealInput() }
        r.step { [self] done in startServer(done) }
        r.closeLittleArcs()
        unattended()
        closeTab()
        navigateAway()
        closeWindow()
        if env["AIRC_PASSKEYQUIT_REAL"] == "1" { realAppleID() }
        quit()
    }

    /// The request alone (nobody pressed anything) puts no sheet on the window and opens no window.
    func unattended() {
        var tab: String?
        var windows = 0
        r.run { windows = NSApp.windows.filter(\.isVisible).count }
        r.step { [self] done in openPending("unattended") { tab = $0; done() } }
        r.wait(3)
        r.step { [self] done in
            let now = attachedSheets()
            let visible = NSApp.windows.filter(\.isVisible).count
            evaluate(tab.flatMap { c?.engineTab(for: $0) }) { s in
                let what = "sheet \(now), sheets begun \(self.sheets.count), visible windows \(windows) → \(visible); \(s.prefix(220))"
                if self.passArm {
                    // The before arm: what WebKit does with the request on its own (the sheet signinfix found, or not).
                    self.note("\(self.guardMode) arm: 3 s after a conditional request reached WebKit: \(what)")
                } else {
                    self.check(now == "none" && self.sheets.isEmpty, "unattended: 3 s after the request no sheet is on any window (\(what))")
                    self.check(visible <= windows, "unattended: no window opened by itself (\(what))")
                }
                if self.webkit, !WebKitPasskeyNotice.entitled {
                    self.check(s.contains("\"available\":\"false\"") && s.contains("rejected NotAllowedError") && now == "none",
                               "unattended: WebKit without the passkey capability answers passkey autofill itself at once, with no sheet (\(s.prefix(220)), sheet \(now))")
                }
                if !self.webkit { self.check(s.contains("\"available\":\"true\""), "unattended: Chromium offers passkey autofill (\(s.prefix(120)))") }
                if let tab, let c = self.c { c.closeTab(tab) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
            }
        }
    }

    /// Closing the tab (⌘W) with the request pending: the tab goes at once and no sheet is left.
    func closeTab() {
        var tab: String?
        r.step { [self] done in openCase("close tab") { tab = $0; done() } }
        r.wait(1.5)
        r.step { [self] done in
            guard let tab, let c else { return done() }
            let before = attachedSheets()
            let t0 = Date()
            let finish = {
                self.r.waitUntil({ c.engineTab(for: tab) == nil && c.shownTabID != tab && self.attachedSheets() == "none" }, timeout: 3) {
                    let gone = c.engineTab(for: tab) == nil && c.shownTabID != tab
                    self.check(gone && self.attachedSheets() == "none",
                               "close tab \(self.mode): ⌘W closes the tab with its passkey request (or SSO sheet) open within 3 s (gone \(gone) after "
                               + String(format: "%.2f s", Date().timeIntervalSince(t0)) + ", sheet before \(before), after \(self.attachedSheets())"
                               + (WebKitPasskeyGuard.lastReport.isEmpty ? "" : "; \(WebKitPasskeyGuard.lastReport)") + ")")
                    done()
                }
            }
            if real, c.shownTabID == tab {
                c.window.makeKeyAndOrderFront(nil)
                key("cmd+w") { ok, out in
                    if !ok { self.note("FAIL-ENV close tab: the driver refused ⌘W (\(out))"); c.closeTab(tab) }
                    finish()
                }
            } else {
                c.closeTab(tab)
                finish()
            }
        }
    }

    /// Going to another page with the request pending: the new page loads and no sheet is left.
    func navigateAway() {
        var tab: String?
        r.step { [self] done in openCase("navigate") { tab = $0; done() } }
        r.wait(1.5)
        r.step { [self] done in
            guard let tab, let c, let page = c.engineTab(for: tab), let to = URL(string: "\(base)/other") else { return done() }
            let t0 = Date()
            page.load(to)
            r.waitUntil({ page.title == "Another page" && !page.isLoading && self.attachedSheets() == "none" }, timeout: 5) {
                self.check(page.title == "Another page" && !page.isLoading && self.attachedSheets() == "none",
                           "navigate: another page loads with the passkey request (or SSO sheet) open within 5 s (\"\(page.title)\" after "
                           + String(format: "%.2f s", Date().timeIntervalSince(t0)) + ", sheet \(self.attachedSheets()))")
                c.closeTab(tab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
            }
        }
    }

    /// Closing a second window (⇧⌘W) whose page has the request pending.
    func closeWindow() {
        var w: WindowController?
        var tab: String?
        r.run { [self] in w = app?.openNewWindow(from: c, commandBar: false) }
        r.wait(0.8)
        r.step { [self] done in
            guard w != nil else { check(false, "close window: a second browser window opens"); return done() }
            openCase("close window", in: { w }) { tab = $0; done() }
        }
        r.wait(1.5)
        r.step { [self] done in
            guard let w, tab != nil, let app else { return done() }
            let before = attachedSheets()
            let t0 = Date()
            let finish = {
                self.r.waitUntil({ !app.controllers.contains { $0 === w } && !w.window.isVisible }, timeout: 3) {
                    let closed = !app.controllers.contains { $0 === w } && !w.window.isVisible
                    self.check(closed && self.attachedSheets() == "none",
                               "close window \(self.mode): ⇧⌘W closes the window with its passkey request (or SSO sheet) open within 3 s (closed \(closed) after "
                               + String(format: "%.2f s", Date().timeIntervalSince(t0)) + ", sheet before \(before), after \(self.attachedSheets()))")
                    if !closed { w.window.close() }
                    self.c?.window.makeKeyAndOrderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
                }
            }
            if real {
                w.window.makeKeyAndOrderFront(nil)
                r.waitUntil({ w.window.isKeyWindow }, timeout: 2) {
                    self.key("cmd+shift+w") { ok, out in
                        if !ok { self.note("FAIL-ENV close window: the driver refused ⇧⌘W (\(out))"); Self.closeWindowCommand(w) }
                        finish()
                    }
                }
            } else {
                Self.closeWindowCommand(w)
                finish()
            }
        }
    }

    static func closeWindowCommand(_ w: WindowController) {
        if let cmd = CommandMenus.all.first(where: { $0.id == "file.closeWindow" }) { cmd.run(w) } else { w.window.performClose(nil) }
    }

    /// appleid.apple.com's sign-in, signed out: no sheet comes by itself; it stays open for the quit.
    func realAppleID() {
        var tab = ""
        r.step { [self] done in
            guard let c, let t = try? c.store.openTab(url: "https://appleid.apple.com/sign-in", inSpace: c.currentSpaceID) else { return done() }
            tab = t.id
            c.show(t.id)
            r.waitUntil({ c.engineTab(for: t.id).map { !$0.isLoading && $0.url?.host != nil } == true }, timeout: 30) { done() }
        }
        r.wait(8)
        r.step { [self] done in
            let page = c?.engineTab(for: tab)
            let now = attachedSheets()
            let what = "(\(page?.url?.host ?? "-"), \"\(page?.title.prefix(40) ?? "-")\", sheet \(now), sheets begun \(sheets.count), "
                + "SSO loads \(WebKitPasskeyGuard.ssoLoads.isEmpty ? "none" : WebKitPasskeyGuard.ssoLoads.joined(separator: "; ")))"
            let probe = "!!(document.querySelector('iframe[src*=\"idmsa.apple.com\"]') || document.querySelector('#aid-auth-widget-iFrame') || document.querySelector('input[type=email], input#account_name_text_field'))"
            guard let shown = page else { check(false, "appleid.apple.com: the real sign-in page opens \(what)"); return done() }
            shown.evaluate(probe) { [self] v in
                let form = (v as? Bool) == true || (v as? NSNumber)?.boolValue == true
                if passArm { note("\(guardMode) arm: appleid.apple.com 8 s after load \(what), sign-in form \(form)") }
                else {
                    check(now == "none" && sheets.isEmpty, "appleid.apple.com: the real sign-in page puts no sheet on the window by itself \(what)")
                    check(form, "appleid.apple.com: its own web sign-in form shows (nothing typed) \(what)")
                }
                done()
            }
        }
    }

    /// The last step: quit with a request pending. The runner checks that the app is gone within 3 s.
    func quit() {
        r.step { [self] done in openCase("quit") { _ in done() } }
        // appleid: quit while WebKit's SSO sheet is attached (it can go by itself a moment later); the fixture: once
        // its request has settled into pending.
        if !appleCases { r.wait(1.5) }
        r.step { [self] _ in
            let how = env["AIRC_PASSKEYQUIT_QUIT"] ?? "hold"
            let sheet = attachedSheets()
            server?.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            note("quit: windows \(NSApp.windows.filter(\.isVisible).count), sheet \(sheet), sheets begun \(sheets.count)"
                 + ", SHEET-AT-QUIT \(sheet == "none" ? "no" : "yes")"
                 + (WebKitPasskeyGuard.lastReport.isEmpty ? "" : "; last ending: \(WebKitPasskeyGuard.lastReport)"))
            if how == "ae" {
                // What the Dock's Quit (and a logout) sends: the quit Apple Event, here to our own process (no TCC).
                note(String(format: "QUIT-SENT %.3f quit Apple Event to ourselves (as the Dock's Quit)", Date().timeIntervalSince1970))
                r.beginQuitByHand()
                let me = NSAppleEventDescriptor(processIdentifier: getpid())
                let quit = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                                                  targetDescriptor: me, returnID: AEReturnID(kAutoGenerateReturnID),
                                                  transactionID: AETransactionID(kAnyTransactionID))
                do { try quit.sendEvent(options: [.noReply], timeout: 5) } catch { note("FAIL quit: the quit Apple Event wasn't sent (\(error))") }
            } else if how == "menu" {
                let menu = NSApp.mainMenu?.items.first?.submenu
                let index = menu?.items.firstIndex { $0.action == #selector(NSApplication.aircQuit(_:)) }
                note(String(format: "QUIT-SENT %.3f menu Quit Airc (item %@)", Date().timeIntervalSince1970, index.map { "\($0)" } ?? "none"))
                r.beginQuitByHand()
                if let menu, let index { menu.performActionForItem(at: index) } else { note("FAIL quit: no Quit Airc menu item") }
            } else {
                // The driver presses and releases ⌘Q at once; the hold that makes it a quit is stood in (the key is
                // "still down" at 0.7 s and its key-up doesn't cancel the hold).
                KeyMonitor.testQuitHold = true
                KeyMonitor.quitIsHeld = { _ in true }
                KeyMonitor.testQuitKeyUpStoodIn = true
                if real {
                    c?.window.makeKeyAndOrderFront(nil)
                    note(String(format: "QUIT-SENT %.3f real ⌘Q (driver key-down; hold stood in)", Date().timeIntervalSince1970))
                    r.beginQuitByHand()
                    key("cmd+q") { ok, out in if !ok { self.note("FAIL-ENV quit: the driver refused ⌘Q (\(out))") } }
                } else {
                    note(String(format: "QUIT-SENT %.3f posted ⌘Q (hold stood in)", Date().timeIntervalSince1970))
                    r.beginQuitByHand()
                    for down in [true, false] {
                        if let e = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: .command,
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c?.window.windowNumber ?? 0,
                                                    context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                }
            }
            // No done(): the app quits here. If it doesn't, the runner's 3 s assertion fails and the quit bound (15 s)
            // ends the process with the main thread's sample.
        }
    }
}
#endif
