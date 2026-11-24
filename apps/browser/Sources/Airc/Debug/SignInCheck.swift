// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// signin (signinfix): every "Sign in" a person can press, on both engines, and one assertion per case: something
/// visible happened (a page, a window, a sheet, a card or a toast that says why). Synthetic only: one loopback
/// fixture plays the sites on two hosts (127.0.0.1 and localhost, so a frame and a pop-up are cross-site), and the
/// sidebar's and Settings' Google sign-ins open the fixture's mock page (never a real account). The last two cases
/// load the real accounts.google.com and appleid.apple.com sign-in pages signed out (nothing is typed), to see that
/// the content blocker leaves them working.
///   Airc's own: the sidebar card's Sign in (key window; app in the background, first click); Settings › Profiles'
///   Sign In… (a profile with a Space; one no Space uses; Switch… on a signed-in one; with no browser window open).
///   Sites: a pop-up on a click; one opened late (Chromium blocks it: the address field's icon, or a toast where that
///   icon can't be seen); target=_blank; a pop-up from a cross-site frame; an app link no app opens; a passkey
///   button; a pop-up from Peek, from a split pane, from Little Airc (the browser window comes forward), from a
///   private window; a first click on a page while Airc is in the background.
/// Clicks are real (the UI driver) with AIRC_REAL_CLICKS=1 in a dedicated session, otherwise posted (labelled).
/// Runner: scripts/tests/signin/run-checks.sh. AIRC_SIGNIN_BEFORE=1 is not an arm: the fixes have no switch; the
/// before numbers come from a build of the base commit (the same script).
extension SnapshotRunner {
    func signInScenario() { SignInCheck(runner: self).start() }
}

final class SignInCheck {
    let r: SnapshotRunner
    let engine: String
    let env = ProcessInfo.processInfo.environment
    var server: LocalPageServer?
    var port: UInt16 = 0
    var openerTab = ""

    init(runner: SnapshotRunner) {
        r = runner
        engine = runner.app?.engine is WebKitEngine ? "WebKit" : "Chromium"
    }

    var real: Bool { env["AIRC_REAL_CLICKS"] == "1" && env["AIRC_UI_DEDICATED_SESSION"] == "1" && UIDriverClient.available }
    var mode: String { real ? "[real]" : "[posted]" }
    var app: AppDelegate? { r.app }
    var c: WindowController? { app?.controller }
    var chromium: Bool { engine == "Chromium" }
    func check(_ ok: Bool, _ s: String) { r.check(ok, "signin \(engine): " + s) }
    func note(_ s: String) { r.note("signin \(engine): " + s) }
    var base: String { "http://127.0.0.1:\(port)" }
    var other: String { "http://localhost:\(port)" }

    // MARK: Fixture

    static let opener = """
    <!doctype html><title>Sign-in fixture</title>
    <style>body{font:16px -apple-system;margin:16px}button,a{display:block;margin:8px 0;font-size:16px;padding:8px 14px}
    iframe{width:360px;height:56px;border:1px solid #999;display:block}</style>
    <button id=popup>Sign in (pop-up)</button>
    <button id=late>Sign in (pop-up after a wait)</button>
    <a id=blank target=_blank>Sign in (new tab)</a>
    <button id=scheme>Sign in with the app</button>
    <button id=passkey>Sign in with a passkey</button>
    <iframe id=frame></iframe>
    <script>
    const tag = new URLSearchParams(location.search).get('c') || 'x';
    const other = (location.hostname === 'localhost' ? 'http://127.0.0.1:' : 'http://localhost:') + location.port;
    document.getElementById('popup').onclick = () => window.open(other + '/auth?popup=' + tag, 'p' + Date.now(), 'width=480,height=600');
    document.getElementById('late').onclick = () => setTimeout(() =>
      window.open(other + '/auth?late=' + tag, 'l' + Date.now(), 'width=480,height=600'), 6000);
    document.getElementById('blank').href = other + '/auth?blank=' + tag;
    document.getElementById('scheme').onclick = () => { location.href = 'airc-signin-noapp-test://sign-in?c=' + tag; };
    document.getElementById('frame').src = other + '/frame?c=' + tag;
    document.getElementById('passkey').onclick = () => {
      window.__ac = new AbortController(); document.body.dataset.pk = 'asked';
      navigator.credentials.get({publicKey: {challenge: new Uint8Array(32), timeout: 20000, userVerification: 'preferred'},
                                 signal: __ac.signal})
        .then(() => document.body.dataset.pk = 'ok', e => document.body.dataset.pk = e.name);
    };
    </script>
    """

    static let frame = """
    <!doctype html><title>frame</title><style>body{margin:0}button{position:fixed;inset:0;width:100%;height:100%;font-size:15px}</style>
    <button id=framepop>Sign in (in a frame)</button>
    <script>const tag = new URLSearchParams(location.search).get('c') || 'x';
    const other = (location.hostname === 'localhost' ? 'http://127.0.0.1:' : 'http://localhost:') + location.port;
    framepop.onclick = () => window.open(other + '/auth?frame=' + tag, 'f' + Date.now(), 'width=420,height=520');</script>
    """

    func startServer(_ done: @escaping () -> Void) {
        server = LocalPageServer(pages: [:])
        server?.requestHandler = { request in
            switch request.path {
            case "/opener": return LocalPageServer.Page(body: Self.opener)
            case "/frame": return LocalPageServer.Page(body: Self.frame)
            case "/auth": return LocalPageServer.Page(body: "<!doctype html><title>Fixture sign-in</title><h1>Fixture sign-in</h1>")
            case "/google-signin": return LocalPageServer.Page(body: "<!doctype html><title>Mock Google sign-in</title><h1>Sign in</h1>")
            case "/ListAccounts": return LocalPageServer.Page(headers: ["Content-Type": "application/json"], body: "[\"gaia.l.a.r\",[]]")
            default: return nil
            }
        }
        server?.start { [self] p in
            port = p ?? 0
            check(port != 0, "the loopback fixture runs (two hosts: 127.0.0.1 and localhost)")
            if port != 0 {
                GoogleAccountProbe.testURL = URL(string: "\(base)/ListAccounts")
                GoogleAccountProbe.testSignInURL = URL(string: "\(base)/google-signin")
                SignInWindowController.testStartURL = URL(string: "\(base)/google-signin")
            }
            done()
        }
    }

    // MARK: Pages and windows

    func url(_ page: EngineTab?) -> String { page?.url?.absoluteString ?? "" }

    /// The browser window shows a page whose address contains `needle`, in front, not under a Peek.
    func browserShows(_ needle: String) -> Bool {
        guard let c, c.window.isVisible, !c.window.isMiniaturized, c.peek == nil, let id = c.shownTabID else { return false }
        return url(c.engineTab(for: id)).contains(needle)
    }

    func browserDetail() -> String {
        guard let c else { return "no browser window" }
        let id = c.shownTabID ?? "-"
        return "shown \(url(c.engineTab(for: id)).replacingOccurrences(of: base, with: "").replacingOccurrences(of: other, with: "~")), "
            + "visible \(c.window.isVisible), minimized \(c.window.isMiniaturized), key \(c.window.isKeyWindow), peek \(c.peek != nil), "
            + "toast \(c.toast.shownText ?? "none")"
    }

    /// `onLocalhost`: the page on the second host (read when the step runs: the port is known only then).
    func loadOpener(_ tag: String, onLocalhost: Bool = false) {
        r.step { [self] done in
            guard let c, let t = try? c.store.openTab(url: "\(onLocalhost ? other : base)/opener?c=\(tag)", inSpace: c.currentSpaceID) else {
                check(false, "\(tag): the fixture page opens"); return done()
            }
            openerTab = t.id
            c.show(t.id)
            r.waitUntil({ c.engineTab(for: t.id).map { $0.title == "Sign-in fixture" && !$0.isLoading } == true }, timeout: 15) {
                let p = c.engineTab(for: t.id)
                if p?.title != "Sign-in fixture" || p?.isLoading != false {
                    self.note("FAIL \(tag): the fixture page didn't load (\(self.url(p)), \"\(p?.title ?? "-")\", loading \(p?.isLoading ?? false), "
                              + "shown \(c.shownTabID == t.id))")
                }
                done()
            }
        }
        r.wait(0.8)   // the frame loads
    }

    func showOpener() {
        r.run { [self] in c?.show(openerTab) }
        r.wait(0.4)
    }

    var openerPage: EngineTab? { c?.engineTab(for: openerTab) }

    func appActive(_ w: NSWindow, _ done: @escaping () -> Void) {
        if NSApp.isActive, w.isKeyWindow { return done() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        r.waitUntil({ NSApp.isActive && w.isKeyWindow }, timeout: 4) {
            if !(NSApp.isActive && w.isKeyWindow) { self.note("FAIL-ENV the window isn't key for a real click") }
            done()
        }
    }

    /// Airc in the background (another app in front), as when the person comes back to it with a click.
    func deactivate(_ done: @escaping () -> Void) {
        NSApp.deactivate()
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [])
        r.waitUntil({ !NSApp.isActive }, timeout: 4) {
            if NSApp.isActive { self.note("FAIL-ENV Airc stayed active; the first-click case runs with it active") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
        }
    }

    /// A press on window point `p`: a real click (after making the window key unless `inactive`), else posted.
    func click(_ p: NSPoint, in w: NSWindow, inactive: Bool = false, _ what: String, _ done: @escaping () -> Void) {
        guard real else {
            if w.isKeyWindow { return r.click(at: p, in: w, done) }
            w.makeKeyAndOrderFront(nil)
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.r.click(at: p, in: w, done) }
        }
        func go() {
            let s = w.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
            let under = NSWindow.windowNumber(at: s, belowWindowWithWindowNumber: 0)
            if inactive || under != w.windowNumber {
                note("\(what): at the click point: \(under == w.windowNumber ? "the target window" : "window \(under) (\(Self.windowOwner(under)))"), "
                     + "target key \(w.isKeyWindow), app active \(NSApp.isActive)")
            }
            UIDriverClient.run(["--click", String(Double(s.x)), String(Double(top - s.y))]) { ok, out in
                if !ok { self.note("FAIL-ENV \(what): the UI driver's click failed (\(out.prefix(160)))") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
            }
        }
        if inactive { return deactivate(go) }
        appActive(w, go)
    }

    /// A press on the page element `id` (in a frame `frame`: the frame's centre, its button fills it).
    func pressPage(_ what: String, _ page: @escaping () -> EngineTab?, _ id: String, inactive: Bool = false) {
        r.step { [self] done in
            guard let p = page(), let w = p.view.window else { check(false, "\(what): the page is in a window"); return done() }
            let js = "(function(){var e=document.getElementById('\(id)');if(!e)return null;e.scrollIntoView({block:'center'});"
                + "var r=e.getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2];})()"
            p.evaluate(js) { v in
                let xy = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                guard xy.count == 2 else { self.check(false, "\(what): #\(id) is on the page"); return done() }
                let view = p.view
                let point = view.convert(NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : view.bounds.height - xy[1]), to: nil)
                if !self.real, inactive { self.note("\(what): no real input in this run; pressed with Airc active [posted]") }
                if self.real {
                    return self.click(point, in: w, inactive: inactive, what) { self.note("\(what): pressed \(self.mode)"); done() }
                }
                if !self.chromium {
                    // Posted window clicks don't reach WebKit pages in -g runs either: the element's own click().
                    return p.evaluate("document.getElementById('\(id)').click()") { _ in self.note("\(what): pressed [posted, element click]"); done() }
                }
                // Posted page clicks don't reach Chromium pages in -g runs (oauthapps): DevTools' Input domain instead,
                // which carries a user activation as a person's click does.
                #if canImport(AircCore)
                if let chromium = self.app?.engine as? ChromiumEngine, p is ChromiumTab {
                    func mouse(_ type: String, _ then: @escaping () -> Void) {
                        chromium.devToolsCall("Input.dispatchMouseEvent", params: ["type": type, "x": xy[0], "y": xy[1], "button": "left",
                                                                                   "clickCount": 1], in: p) { _, _ in then() }
                    }
                    return mouse("mousePressed") { mouse("mouseReleased") { self.note("\(what): pressed [posted, page input]"); done() } }
                }
                #endif
                self.click(point, in: w, what) { done() }
            }
        }
    }

    /// One assertion: `cond` within `timeout`.
    func expect(_ what: String, timeout: Double = 8, _ cond: @escaping () -> Bool, _ detail: @escaping () -> String) {
        r.step { [self] done in
            r.waitUntil(cond, timeout: timeout) {
                self.check(cond(), "\(what) (\(detail()))")
                done()
            }
        }
    }

    /// The window is in front: key with real input; in a posted (background) run, where Airc is never activated and
    /// the window order isn't a person's, on screen and not minimized ("in front" is the real-click runs' assertion).
    func inFront(_ w: NSWindow?) -> Bool {
        guard let w, w.isVisible, !w.isMiniaturized else { return false }
        return real ? w.isKeyWindow : true
    }

    var popupIndicatorShown: Bool {
        guard let c, !c.sidebarHidden else { return false }
        return c.pageView(for: c.currentSpaceID)?.urlField.siteIndicators.kinds.contains(.popup) == true
    }

    // MARK: The run

    /// Every sheet that begins, as it begins (also during the quit): what holds a quit up shows in the log.
    static var sheetObserver: NSObjectProtocol?
    static func texts(_ v: NSView?) -> [String] {
        guard let v else { return [] }
        let own = (v as? NSTextField).map { [$0.stringValue] } ?? []
        return own + v.subviews.flatMap { texts($0) }
    }

    func start() {
        Self.sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main) {
            [weak r = self.r] n in
            guard let parent = n.object as? NSWindow else { return }
            DispatchQueue.main.async {
                let sheet = parent.attachedSheet
                let words = Self.texts(sheet?.contentView).filter { !$0.isEmpty }.joined(separator: " | ").prefix(200)
                r?.note("signin sheet: \(sheet.map { "\(type(of: $0))" } ?? "-") on \(type(of: parent)) \"\(parent.title.prefix(40))\": \(words)")
            }
        }
        if real { r.activateForRealInput() }
        r.step { [self] done in startServer(done) }
        r.closeLittleArcs()
        sidebarCard()
        settings()
        sites()
        peekSplitLittlePrivate()
        passkey()
        noBrowserWindow()
        realAccountsPages()
        // What's open as the run ends (a quit held up by a sheet, a modal or a window shows here).
        r.run { [self] in
            let wins = NSApp.windows.filter(\.isVisible).map { w in
                "\(type(of: w))\(w.attachedSheet.map { " sheet \(type(of: $0))" } ?? "")\(w.title.isEmpty ? "" : " \"\(w.title.prefix(30))\"")"
            }
            note("end: modal \(NSApp.modalWindow.map { "\(type(of: $0))" } ?? "none"), visible windows \(wins.joined(separator: "; ")), "
                 + "settings sign-in \(SettingsSignIn.current != nil)")
        }
        r.run { [self] in
            GoogleAccountProbe.testURL = nil
            GoogleAccountProbe.testSignInURL = nil
            SignInWindowController.testStartURL = nil
            server?.stop()
        }
    }

    // MARK: Airc's own sign-ins

    func makeProfile(_ name: String, space: Bool) -> (profile: String, space: String?)? {
        guard let c, let p = try? c.profiles.createProfile(name: name, emoji: "🔑", color: nil) else { return nil }
        guard space else { return (p.id, nil) }
        let s = try? c.store.createSpace(name: name, theme: .single("7EB6D5"), profileID: p.id)
        return (p.id, s?.id)
    }

    func sidebarCard() {
        for inactive in [false, true] {
            let tag = inactive ? "card-first-click" : "card"
            var made: (profile: String, space: String?)?
            r.run { [self] in made = makeProfile("Sign-in \(tag)", space: true) }
            r.step { [self] done in if let c { c.profiles.loadAll(completion: done) } else { done() } }
            r.run { [self] in
                guard let c, let sid = made?.space else { return }
                c.switchToSpace(sid, animated: false)
                c.reloadAll(animated: false)
            }
            r.wait(0.6)
            r.step { [self] done in
                guard let c, let sid = made?.space else { check(false, "\(tag): a new profile with its own Space"); return done() }
                c.window.contentView?.layoutSubtreeIfNeeded()
                guard let card = r.signInCard(sid),
                      let hit = MainActor.assumeIsolated({ r.signInButtonPoint(card, AircSignInCopy.signIn) }) else {
                    check(false, "\(tag): the new profile's Space shows the Sign in card"); return done()
                }
                guard real || !inactive else {
                    MainActor.assumeIsolated { card.onSignIn() }
                    note("\(tag): Sign in pressed by its action (no real input in this run)")
                    return done()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.1) {
                    self.click(hit.0, in: c.window, inactive: inactive, "\(tag) Sign in") { self.note("\(tag): Sign in pressed \(self.mode) (\(hit.1) point)"); done() }
                }
            }
            expect("\(tag): the sidebar card's Sign in opens the sign-in page in that Space, in front \(mode)\(inactive ? ", Airc in the background" : "")",
                   { self.browserShows("/google-signin") && self.c?.currentSpaceID == made?.space
                       && self.c.map { $0.store.tab($0.shownTabID)?.profileID == made?.profile } == true },
                   { self.browserDetail() })
            r.run { [self] in if let pid = made?.profile { try? c?.store.finishGoogleSignIn(pid, choice: .dismissed) } }
        }
    }

    func settings() {
        var withSpace: (profile: String, space: String?)?
        var noSpace: (profile: String, space: String?)?
        r.run { [self] in
            withSpace = makeProfile("Settings sign-in", space: true)
            noSpace = makeProfile("No Space sign-in", space: false)
        }
        r.step { [self] done in if let c { c.profiles.loadAll(completion: done) } else { done() } }
        r.run { [self] in app?.showSettings(page: .profiles) }
        r.wait(0.5)
        func press(_ pid: @escaping () -> String?) {
            r.run { [self] in
                guard let app, let model = app.settingsWindow?.model, let p = pid().flatMap({ app.store.profile($0) }) else {
                    return check(false, "Settings › Profiles is open for the case's profile")
                }
                SettingsActions.signIn(profile: p, model: model)
                note("Settings › Profiles: \(p.googleAccount == nil ? "Sign In…" : "Switch…") for \(p.name) pressed by its action")
            }
        }
        press { withSpace?.profile }
        expect("settings: Sign In… for a profile with a Space opens its sign-in page in the browser window, in front",
               { self.browserShows("/google-signin") && self.c?.currentSpaceID == withSpace?.space && self.inFront(self.c?.window) },
               { self.browserDetail() })
        r.run { [self] in if let pid = withSpace?.profile { try? c?.store.finishGoogleSignIn(pid, choice: .dismissed) } }
        // Signed in already: Switch….
        r.run { [self] in
            if let pid = withSpace?.profile {
                try? c?.store.keepGoogleAccount(pid, account: GoogleAccount(name: "Ada Example", email: "ada@example.com"), index: 0)
            }
            app?.showSettings(page: .profiles)
        }
        r.wait(0.3)
        press { withSpace?.profile }
        expect("settings: Switch… for a signed-in profile opens the sign-in page, in front",
               { self.browserShows("/google-signin") && self.inFront(self.c?.window) }, { self.browserDetail() })
        r.run { [self] in
            if let pid = withSpace?.profile { try? c?.store.finishGoogleSignIn(pid, choice: .dismissed) }
            app?.showSettings(page: .profiles)
        }
        r.wait(0.3)
        // No Space uses the profile: before, nothing at all.
        press { noSpace?.profile }
        expect("settings: Sign In… for a profile no Space uses opens Google's sign-in window in that profile (before: nothing)",
               { SettingsSignIn.current?.window.isVisible == true && self.url(SettingsSignIn.current?.page).contains("/google-signin") },
               { "window \(SettingsSignIn.current.map { "visible \($0.window.isVisible), \(self.url($0.page).replacingOccurrences(of: self.base, with: ""))" } ?? "none")" })
        r.run { SettingsSignIn.current?.close() }
        r.run { [self] in app?.settingsWindow?.window.orderOut(nil) }
    }

    // MARK: Site sign-in buttons

    func sites() {
        loadOpener("main")
        pressPage("pop-up \(mode)", { self.openerPage }, "popup")
        expect("pop-up: a site's sign-in pop-up opens in front \(mode)", { self.browserShows("/auth?popup=main") }, { self.browserDetail() })
        showOpener()
        pressPage("new tab \(mode)", { self.openerPage }, "blank")
        expect("target=_blank: a sign-in link to a new tab opens it in front \(mode)", { self.browserShows("/auth?blank=main") }, { self.browserDetail() })
        showOpener()
        if real || chromium {
            pressPage("frame \(mode)", { self.openerPage }, "frame")
            expect("frame: a cross-site frame's sign-in pop-up opens in front \(mode)", { self.browserShows("/auth?frame=main") }, { self.browserDetail() })
            showOpener()
        } else {
            note("frame: real clicks only on WebKit (a posted window click never reaches a WebKit frame in a background run)")
        }
        // A pop-up opened 6 s after the click (no user activation left): Chromium blocks it and says so in the address
        // field; WebKit opens it.
        pressPage("late pop-up \(mode)", { self.openerPage }, "late")
        expect("late pop-up: a blocked pop-up shows the address field's Pop-up blocked icon, or opens", timeout: 12,
               { self.popupIndicatorShown || self.browserShows("/auth?late=main") },
               { "indicator \(self.popupIndicatorShown), \(self.browserDetail())" })
        // The same with the sidebar hidden (the icon out of sight): a toast with Open.
        r.run { [self] in c?.show(openerTab); if c?.sidebarHidden == false { c?.toggleSidebar() } }
        r.wait(0.8)
        pressPage("late pop-up, sidebar hidden \(mode)", { self.openerPage }, "late")
        expect("late pop-up, sidebar hidden: a toast says Pop-up blocked (with Open), or it opens (before: nothing)", timeout: 12,
               { self.c?.toast.shownText == BlockedPopupNotice.text || self.browserShows("/auth?late=main") },
               { self.browserDetail() })
        if chromium {
            r.step { [self] done in
                guard let b = c?.toast.actionButton, let w = c?.window else { return done() }
                let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
                click(p, in: w, "toast Open") { done() }
            }
            expect("late pop-up, sidebar hidden: the toast's Open opens the blocked pop-up", { self.browserShows("/auth?late=main") },
                   { self.browserDetail() })
        }
        r.run { [self] in if c?.sidebarHidden == true { c?.toggleSidebar() } }
        r.wait(0.8)
        showOpener()
        pressPage("app link \(mode)", { self.openerPage }, "scheme")
        expect("app link: a sign-in that hands off to an app no app opens says \"No app opens this link\"",
               {
                   if case .externalApp(let e)? = self.c?.prompts.shown?.prompt { return e.app == nil && self.c?.prompts.bubble != nil }
                   return false
               },
               { "prompt \(self.c?.prompts.shown.map { "\($0.prompt)" } ?? "none")" })
        r.step { [self] done in
            guard let c, let b = c.prompts.bubble else { return done() }
            b.layoutSubtreeIfNeeded()
            guard let p = r.anchorPoint("prompt.ok", in: b.hostingView) else { return done() }
            click(p, in: c.window, "prompt OK") { done() }
        }
        // First click on the page while Airc is in the background: Chrome's rule in the browser window is that the
        // click brings the window forward (the page gets the next one).
        showOpener()
        pressPage("page first click", { self.openerPage }, "popup", inactive: true)
        expect("first click on a page with Airc in the background brings the window forward (Chrome: the page takes the next click)",
               { NSApp.isActive && self.inFront(self.c?.window) || self.browserShows("/auth?popup=main") },
               { "active \(NSApp.isActive), \(self.browserDetail())" })
    }

    func peekSplitLittlePrivate() {
        // Peek: a pop-up from a page in Peek shows in front (before: under the Peek card).
        showOpener()
        r.step { [self] done in
            guard let c, let o = openerPage, let u = URL(string: "\(base)/opener?c=peek") else { return done() }
            c.openPeek(u, from: o)
            r.waitUntil({ c.peek?.page.title == "Sign-in fixture" && c.peek?.page.isLoading == false }, timeout: 12) { done() }
        }
        r.wait(0.8)
        pressPage("Peek pop-up \(mode)", { self.c?.peek?.page }, "popup")
        expect("peek: a sign-in pop-up from a page in Peek opens in front, the Peek kept as a tab (before: under the Peek card)",
               { self.browserShows("/auth?popup=peek") && self.c?.store.state.tabs.values.contains { $0.url.contains("/opener?c=peek") } == true },
               { self.browserDetail() })
        // Split view (Chromium only: WebKit has no Split View).
        if chromium {
            var second = ""
            r.step { [self] done in
                guard let c, let t = try? c.store.openTab(url: "\(base)/opener?c=split", inSpace: c.currentSpaceID),
                      let x = try? c.store.createSplit([openerTab, t.id], inSpace: c.currentSpaceID, focused: t.id) else {
                    check(false, "split: a split of two fixture pages"); return done()
                }
                second = t.id
                _ = c.showSplit(x, focus: t.id)
                r.waitUntil({ c.engineTab(for: t.id).map { $0.title == "Sign-in fixture" && !$0.isLoading } == true }, timeout: 12) { done() }
            }
            r.wait(0.8)
            pressPage("split pop-up \(mode)", { self.c?.engineTab(for: second) }, "popup")
            expect("split: a sign-in pop-up from a split pane opens in front", { self.browserShows("/auth?popup=split") }, { self.browserDetail() })
        }
        // Little Airc: its pop-up goes to the browser window, which comes forward (before: it stayed minimized).
        var little: LittleArcController?
        r.step { [self] done in
            guard let c else { return done() }
            c.window.miniaturize(nil)
            r.waitUntil({ c.window.isMiniaturized }, timeout: 4) {
                little = self.app?.openLittleArc(url: URL(string: "\(self.base)/opener?c=little"), spaceID: c.currentSpaceID)
                self.r.waitUntil({ little?.page.map { $0.title == "Sign-in fixture" && !$0.isLoading } == true }, timeout: 15) { done() }
            }
        }
        r.wait(0.8)
        pressPage("Little Airc pop-up \(mode)", { little?.page }, "popup")
        expect("little arc: a sign-in pop-up from Little Airc opens in the browser window, which comes forward (before: it stayed minimized)",
               timeout: 10, { self.browserShows("/auth?popup=little") }, { "\(self.browserDetail()), handed \(little?.poppedToBrowser ?? -1)" })
        if chromium {
            pressPage("Little Airc late pop-up \(mode)", { little?.page }, "late")
            expect("little arc: a blocked pop-up in Little Airc shows a toast with Open (before: nothing)", timeout: 12,
                   { little?.toast.shownText == BlockedPopupNotice.text }, { "toast \(little?.toast.shownText ?? "none")" })
        }
        // A first click on Little Airc's page with Airc in the background reaches the page (LA-1's first press). Little
        // Airc in front first (the pop-up case brought the browser window over it), as after a link from another app.
        r.step { [self] done in
            guard let w = little?.window else { return done() }
            w.makeKeyAndOrderFront(nil)
            r.waitUntil({ w.isKeyWindow }, timeout: 3) { done() }
        }
        r.wait(0.5)
        func littleDetail() -> String {
            "\(self.browserDetail()); Little Airc page \(self.url(little?.page).replacingOccurrences(of: self.base, with: "")), key "
                + "\(little?.window.isKeyWindow ?? false), handed \(little?.poppedToBrowser ?? -1), presses sent again \(little?.replayedPresses ?? -1), "
                + "active \(NSApp.isActive)"
        }
        // Control: the same new-tab link with Airc active and Little Airc key.
        var handed = 0
        r.run { handed = little?.poppedToBrowser ?? 0 }
        pressPage("Little Airc new tab (active) \(mode)", { little?.page }, "blank")
        expect("little arc: a new-tab sign-in link in Little Airc opens in the browser window, in front", timeout: 10,
               { (little?.poppedToBrowser ?? 0) > handed && self.browserShows("/auth?blank=little") }, { littleDetail() })
        r.step { [self] done in
            guard let w = little?.window else { return done() }
            w.makeKeyAndOrderFront(nil)
            r.waitUntil({ w.isKeyWindow }, timeout: 3) { done() }
        }
        r.wait(0.5)
        r.run { handed = little?.poppedToBrowser ?? 0 }
        pressPage("Little Airc first click", { little?.page }, "popup", inactive: true)
        expect("little arc: a first click on its page's Sign in with Airc in the background works (the pop-up opens in the browser window)",
               timeout: 10, { (little?.poppedToBrowser ?? 0) > handed && self.browserShows("/auth?popup=little") }, { littleDetail() })
        r.closeLittleArcs()
        // A private window: its pop-up is a page of that window.
        var priv: PrivateWindowController?
        r.step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                priv = w
                _ = w?.openPage(URL(string: "\(self.base)/opener?c=private"))
                self.r.waitUntil({ w?.shownPage.map { $0.title == "Sign-in fixture" && !$0.isLoading } == true }, timeout: 15) { done() }
            }
        }
        r.wait(0.8)
        pressPage("private pop-up \(mode)", { priv?.shownPage }, "popup")
        expect("private: a sign-in pop-up in a private window opens in front in that window",
               { self.url(priv?.shownPage).contains("/auth?popup=private") && priv?.window.isVisible == true },
               { "shown \(self.url(priv?.shownPage).replacingOccurrences(of: self.other, with: "~"))" })
        if chromium {
            r.step { [self] done in
                guard let p = priv, let first = p.pages.first else { return done() }
                p.window.makeKeyAndOrderFront(nil)
                // Back to the fixture page (the pop-up stays in the window).
                p.select(first.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
            pressPage("private late pop-up \(mode)", { priv?.shownPage }, "late")
            expect("private: a blocked pop-up in a private window shows a toast with Open (before: nothing)", timeout: 12,
                   { priv?.toast.shownText == BlockedPopupNotice.text }, { "toast \(priv?.toast.shownText ?? "none")" })
        }
        r.step { [self] done in
            priv?.closeWindow()
            r.waitUntil({ PrivateBrowsing.shared.windows.isEmpty }, timeout: 5) { done() }
        }
        r.run { [self] in c?.window.makeKeyAndOrderFront(nil) }
    }

    /// A passkey button: a system or Airc sheet comes up (or the page hears why not at once); never silence.
    func passkey() {
        loadOpener("pk", onLocalhost: true)   // localhost: a secure context with a valid RP ID
        var before: Set<Int> = []
        r.run { before = Set(Self.onScreenWindows()) }
        pressPage("passkey \(mode)", { self.openerPage }, "passkey")
        var answer = ""
        r.step { [self] done in
            let deadline = Date().addingTimeInterval(6)
            func poll() {
                openerPage?.evaluate("document.body.dataset.pk || ''") { v in
                    answer = v as? String ?? ""
                    let appeared = Set(Self.onScreenWindows()).subtracting(before)
                    let settled = (answer != "asked" && !answer.isEmpty) && (answer != "NotAllowedError" || self.c?.toast.shownText != nil
                                                                              || Date() > deadline.addingTimeInterval(-4))
                    if !appeared.isEmpty || settled || Date() > deadline {
                        let what = appeared.map { Self.windowOwner($0) }.joined(separator: ", ")
                        let toast = self.c?.toast.shownText
                        self.check(!appeared.isEmpty || toast == BlockedPopupNotice.passkeyText
                                   || (answer != "asked" && !answer.isEmpty && answer != "NotAllowedError"),
                                   "passkey: Sign in with a passkey brings up a sheet, or says why it can't (sheet \(what.isEmpty ? "none" : what); "
                                   + "toast \(toast ?? "none"); page: \(answer.isEmpty ? "-" : answer); entitled \(WebKitPasskeyNotice.entitled))")
                        return done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
                }
            }
            poll()
        }
        r.step { [self] done in
            openerPage?.evaluate("[String(window.__aircPasskeyWatch), typeof navigator.credentials, typeof PublicKeyCredential, "
                                 + "String(navigator.credentials && navigator.credentials.get).includes('native code'), "
                                 + "!!(window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(WebKitPasskeyNotice.messageName))].join(', ')") { v in
                self.note("passkey: page watcher, credentials type, PublicKeyCredential type, get native, handler: \(v as? String ?? "-")")
                done()
            }
        }
        r.run { [self] in openerPage?.evaluate("window.__ac && __ac.abort()") { _ in } }
        r.wait(1)
    }

    static func onScreenWindows() -> [Int] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int ?? 99) <= 25,
                  let b = d[kCGWindowBounds as String] as? [String: Double], (b["Width"] ?? 0) > 120, (b["Height"] ?? 0) > 80 else { return nil }
            return d[kCGWindowNumber as String] as? Int
        }
    }

    static func windowOwner(_ n: Int) -> String {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(n)) as? [[String: Any]] ?? []
        return list.first.flatMap { $0[kCGWindowOwnerName as String] as? String } ?? "window \(n)"
    }

    /// Settings › Profiles' Sign In… with every browser window closed: a window opens with the sign-in page.
    func noBrowserWindow() {
        var pid: String?
        r.run { [self] in pid = makeProfile("No window sign-in", space: true)?.profile }
        r.step { [self] done in if let c { c.profiles.loadAll(completion: done) } else { done() } }
        r.step { [self] done in
            app?.controllers.forEach { $0.window.performClose(nil) }
            r.waitUntil({ self.app?.controllers.isEmpty == true }, timeout: 6) {
                self.note("no browser window: \(self.app?.controllers.count ?? -1) left")
                self.app?.showSettings(page: .profiles)
                done()
            }
        }
        r.run { [self] in
            guard let app, let model = app.settingsWindow?.model, let p = pid.flatMap({ app.store.profile($0) }) else { return }
            SettingsActions.signIn(profile: p, model: model)
        }
        expect("settings: Sign In… with no browser window open opens one with the sign-in page (before: nothing)",
               { self.browserShows("/google-signin") }, { self.browserDetail() })
        r.run { [self] in
            if let pid { try? c?.store.finishGoogleSignIn(pid, choice: .dismissed) }
            app?.settingsWindow?.window.orderOut(nil)
        }
    }

    // MARK: Real accounts pages (signed out; nothing typed)

    static let pageSummary = "(function(){var t=(document.body&&document.body.innerText||'').replace(/\\s+/g,' ').slice(0,240);"
        + "var s=[...document.scripts].map(x=>{try{return new URL(x.src).host}catch(e){return 'inline'}});"
        + "return 'ready '+document.readyState+', inputs '+document.querySelectorAll('input').length+', scripts '+[...new Set(s)].join(' ')+', text: '+t;})()"

    func realAccountsPages() {
        let cases: [(String, String, String)] = [
            ("accounts.google.com", "https://accounts.google.com/ServiceLogin?hl=en",
             "!!document.querySelector('input[type=email], input[name=identifier], #identifierId')"),
            ("appleid.apple.com", "https://appleid.apple.com/sign-in",
             "!!(document.querySelector('iframe[src*=\"idmsa.apple.com\"]') || document.querySelector('#aid-auth-widget-iFrame') || document.querySelector('input[type=email], input#account_name_text_field'))"),
        ]
        var opened: [String] = []
        defer {
            // WebKit: appleid.apple.com's sign-in asks for a passkey sheet (AuthenticationServices, a remote ViewBridge
            // panel) on its own, which holds a quit until it's answered. Logged as found, then ended, and the real
            // pages closed, so the run's quit says what it means.
            r.step { [self] done in
                for w in NSApp.windows { if let sheet = w.attachedSheet {
                    note("found: a sheet left on \(type(of: w)) \"\(w.title.prefix(40))\" after the real pages (\(type(of: sheet))); ended by the check")
                    w.endSheet(sheet)
                } }
                opened.forEach { c?.closeTab($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done)
            }
        }
        for (host, address, probe) in cases {
            var tab = ""
            r.step { [self] done in
                guard let c, let t = try? c.store.openTab(url: address, inSpace: c.currentSpaceID) else { return done() }
                tab = t.id
                opened.append(t.id)
                c.show(t.id)
                r.waitUntil({ c.engineTab(for: t.id).map { !$0.isLoading && $0.url?.host != nil } == true }, timeout: 30) { done() }
            }
            r.step { [self] done in
                let deadline = Date().addingTimeInterval(20)
                func poll() {
                    guard let page = c?.engineTab(for: tab) else { check(false, "\(host): the page opens"); return done() }
                    page.evaluate(probe) { v in
                        let ok = (v as? Bool) == true || (v as? NSNumber)?.boolValue == true
                        if ok || Date() > deadline {
                            let blocked = MainActor.assumeIsolated { BlockingCenter.shared?.count(for: page) }
                            let what = "(\(page.url?.host ?? "-"), \"\(page.title.prefix(40))\", Airc blocked \(blocked.map { "\($0)" } ?? "-") request(s))"
                            if ok {
                                self.check(true, "\(host): the real sign-in page loads signed out with its sign-in form " + what)
                                return done()
                            }
                            // No form: what the page says, then the same page with Airc's blocking off for the site. If
                            // the form comes then, Airc's blocker broke it (a FAIL); if not, it's the site's own answer.
                            page.evaluate(Self.pageSummary) { v in
                                self.note("\(host): no sign-in form with blocking on \(what); page: \(v as? String ?? "-")")
                                MainActor.assumeIsolated {
                                    BlockingCenter.shared?.setSiteEnabled(false, tab: page)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    self.r.waitUntil({ !page.isLoading }, timeout: 20) {
                                        let off = Date().addingTimeInterval(15)
                                        func again() {
                                            page.evaluate(probe) { v2 in
                                                let ok2 = (v2 as? Bool) == true || (v2 as? NSNumber)?.boolValue == true
                                                if ok2 || Date() > off {
                                                    page.evaluate(Self.pageSummary) { s2 in
                                                        self.note("\(host): blocking off for the site: form \(ok2); page: \(s2 as? String ?? "-")")
                                                        self.check(!ok2, "\(host): Airc's blocker doesn't break the sign-in page (form with blocking on false, "
                                                                   + "off \(ok2): \(ok2 ? "the blocker broke it" : "the site's own page, not Airc") \(what)")
                                                        MainActor.assumeIsolated { BlockingCenter.shared?.setSiteEnabled(true, tab: page) }
                                                        done()
                                                    }
                                                    return
                                                }
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: again)
                                            }
                                        }
                                        again()
                                    }
                                }
                            }
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
                    }
                }
                poll()
            }
        }
    }
}
#endif
