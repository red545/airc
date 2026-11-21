// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircDesign
import AircKit
import AppKit
import Network
import WebKit

/// SP-12 / ON-3: a new profile's sidebar card, end to end, on synthetic Google answers only (never a real account).
/// One loopback fixture plays Google on made-up hosts under airc-fixture.co.uk: a sign-in page whose account links set
/// a per-profile cookie and redirect to another host (as Google's sign-in ends on myaccount), and a ListAccounts that
/// answers from that cookie, so each profile's own cookie jar decides what GoogleAccountProbe sees.
/// Chromium reaches it through `--host-resolver-rules=MAP *.airc-fixture.co.uk 127.0.0.1 --disable-features=HttpsUpgrades`
/// (launch arguments), WebKit through the test profiles' own CONNECT proxy (only that domain).
///
/// Cases, each on a new profile with its own Space: Sign in (real click) → fixture sign-in → the avatar (picture), name
/// and email update → the card offers Gmail, Calendar and Drive → Add (real click) pins them as that account (u/0);
/// Skip after sign-in; ✕ before sign-in (never shown again, a late answer can't bring it back); a profile already
/// signed in to one account that signs in to a second gets the second, at u/1.
/// Real clicks need AIRC_REAL_KEYS=1, AIRC_UI_DEDICATED_SESSION=1 and the stable UI driver; without them (the suite)
/// the card's buttons are pressed by their actions and the log says so.
/// Run twice on the same scratch data: the second process verifies what was kept, without network.
extension SnapshotRunner {
    private struct SignInCase {
        let name: String
        /// Signed in on the web before the card's Sign in (the second-account case).
        let before: String?
        /// The account the fixture sign-in completes with; nil: the card is closed before signing in.
        let signIn: String?
        let answer: String
        let index: Int
    }

    private static let signInCases = [
        SignInCase(name: "Sign-in Add", before: nil, signIn: "alex@example.com", answer: AircSignInCopy.add, index: 0),
        SignInCase(name: "Sign-in Skip", before: nil, signIn: "alex@example.com", answer: AircSignInCopy.skip, index: 0),
        SignInCase(name: "Sign-in Close", before: nil, signIn: nil, answer: "Dismiss", index: 0),
        SignInCase(name: "Sign-in Second", before: "blair@example.com", signIn: "alex@example.com", answer: AircSignInCopy.add, index: 1),
    ]

    func profileSignInMain(_ action: @escaping @MainActor () -> Void) {
        run { MainActor.assumeIsolated { action() } }
    }

    var signInReal: Bool {
        UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
    }

    func signInFind<T: NSView>(_ root: NSView?, _: T.Type) -> T? {
        guard let root else { return nil }
        if let v = root as? T { return v }
        return root.subviews.lazy.compactMap { self.signInFind($0, T.self) }.first
    }

    func signInCard(_ spaceID: String) -> AircSignInCardView? {
        signInFind(c.pageView(for: spaceID), AircSignInCardView.self)
    }

    /// The card button's centre in window points: from the hosting view's accessibility tree, else from the card's
    /// layout (AircSidebarCard: 12/10 pt insets, the ✕ 7 pt in from the top right).
    @MainActor func signInButtonPoint(_ card: AircSignInCardView, _ title: String) -> (NSPoint, String)? {
        guard let window = card.window else { return nil }
        let cardRect = card.convert(card.bounds, to: nil)
        func walk(_ e: Any, _ depth: Int) -> NSRect? {
            guard depth < 16, let a = e as? NSAccessibilityProtocol else { return nil }
            let labels = [a.accessibilityTitle(), a.accessibilityLabel()].compactMap { $0 }
            if a.accessibilityRole() == .button, labels.contains(title) { return a.accessibilityFrame() }
            for child in a.accessibilityChildren() ?? [] { if let r = walk(child, depth + 1) { return r } }
            return nil
        }
        if let screen = walk(card, 0) {
            let r = window.convertFromScreen(screen)
            let p = NSPoint(x: r.midX, y: r.midY)
            if cardRect.contains(p) { return (p, "accessibility") }
        }
        let font = AircFont.callout.appFont
        let primary = ceil(NSAttributedString(string: AircSignInCopy.add, attributes: [.font: font]).size().width) + 20
        let local: NSPoint
        switch title {
        case "Dismiss": local = NSPoint(x: card.bounds.maxX - 17, y: card.bounds.maxY - 17)
        case AircSignInCopy.signIn, AircSignInCopy.add: local = NSPoint(x: 12 + 14, y: 10 + 10)
        default: local = NSPoint(x: 12 + primary + 4 + 16, y: 10 + 10)
        }
        return (card.convert(card.isFlipped ? NSPoint(x: local.x, y: card.bounds.maxY - local.y) : local, to: nil), "layout")
    }

    /// Presses `title` on the space's card: a real click when this run may, else the card's own action.
    func signInPress(_ tag: String, _ spaceID: @escaping () -> String, _ title: String) {
        step { [self] done in
            c.window.contentView?.layoutSubtreeIfNeeded()
            guard let card = signInCard(spaceID()) else { check(false, "profilesignin \(tag): the card is drawn to press \(title)"); return done() }
            guard signInReal else {
                MainActor.assumeIsolated {
                    switch title {
                    case AircSignInCopy.signIn, AircSignInCopy.add: card.onSignIn()
                    case "Dismiss": card.onDismiss?()
                    default: card.onNotNow()
                    }
                }
                note("profilesignin \(tag): \(title) pressed by its action (no real input in this run)")
                return done()
            }
            // Past the double-click interval since the last press, laid out again at click time.
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.15) { [self] in
                c.window.contentView?.layoutSubtreeIfNeeded()
                guard let card = signInCard(spaceID()), let hit = MainActor.assumeIsolated({ signInButtonPoint(card, title) }) else {
                    check(false, "profilesignin \(tag): \(title) has a place on screen"); return done()
                }
                let (p, how) = hit
                let s = c.window.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
                func click() {
                    UIDriverClient.run(["--click", String(Double(s.x)), String(Double(top - s.y))]) { ok, out in
                        if !ok { self.note("FAIL-ENV profilesignin \(tag): the driver's click on \(title) (\(out.prefix(200)))") }
                        else { self.note("profilesignin \(tag): \(title) real click (\(how) point)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                    }
                }
                if signInFocused(at: s) { return click() }
                // Focus lost (another app or window took it): re-activate our window once, then click; if that
                // doesn't bring it back, end the run now with the reason instead of waiting out every later step
                // until the 240 s watchdog (release059, 0.1.47: the app was idle, not hung).
                let lost = signInFocusState(at: s)
                note("profilesignin \(tag): focus lost at \(title) (\(lost)); re-activating our window once")
                signInReactivate { [self] in
                    guard signInFocused(at: s) else {
                        return finishForcing("FAIL-ENV profilesignin \(tag): focus lost at \(title) and not back after one re-activation "
                                             + "(before: \(lost); after: \(signInFocusState(at: s))); ending the run now, not at the watchdog")
                    }
                    note("profilesignin \(tag): focus back at \(title) after one re-activation")
                    click()
                }
            }
        }
    }

    /// Whether a real click at `s` (screen points) lands in our active key window on the active Space.
    func signInFocused(at s: NSPoint) -> Bool {
        NSApp.isActive && c.window.isKeyWindow && c.window.isOnActiveSpace
            && NSWindow.windowNumber(at: s, belowWindowWithWindowNumber: 0) == c.window.windowNumber
    }

    /// What's wrong with the focus, named, for the log.
    func signInFocusState(at s: NSPoint) -> String {
        let front = NSWorkspace.shared.frontmostApplication
        let over = NSWindow.windowNumber(at: s, belowWindowWithWindowNumber: 0)
        return "app active \(NSApp.isActive), window key \(c.window.isKeyWindow), on active Space \(c.window.isOnActiveSpace), "
            + "window at the point \(over == c.window.windowNumber ? "ours" : "another (\(over))"), "
            + "frontmost \(front?.bundleIdentifier ?? front?.localizedName ?? "none")"
    }

    /// One re-activation, with the helpers the runner already uses (activateForRealInput's activate + key, then
    /// signInFront's click on the gap below the page if still not key). No AppleScript.
    func signInReactivate(_ then: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
        waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) { [self] in
            guard !(NSApp.isActive && c.window.isKeyWindow), UIDriverClient.available else { return then() }
            let card = c.card.convert(c.card.bounds, to: nil)
            let g = c.window.convertPoint(toScreen: NSPoint(x: card.midX, y: card.minY - AircMetrics.Window.cardInset / 2 - 1))
            // Never click into another app's window: only when our window is the one under the gap.
            guard NSWindow.windowNumber(at: g, belowWindowWithWindowNumber: 0) == c.window.windowNumber else { return then() }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))]) { _, _ in
                self.waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) { then() }
            }
        }
    }

    /// Our window in front and key for real clicks (one click on the gap below the page, which does nothing else).
    func signInFront() {
        activateForRealInput()
        step { [self] done in
            guard signInReal, !(NSApp.isActive && c.window.isKeyWindow) else { return done() }
            let card = c.card.convert(c.card.bounds, to: nil)
            let s = c.window.convertPoint(toScreen: NSPoint(x: card.midX, y: card.minY - AircMetrics.Window.cardInset / 2 - 1))
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            UIDriverClient.run(["--click", String(Double(s.x)), String(Double(top - s.y))]) { _, _ in
                self.waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) { done() }
            }
        }
    }

    /// Loads `url` in a page and waits until `ready` (JavaScript) says true; `then(ok)`.
    func signInPage(_ tab: @escaping () -> EngineTab?, until ready: String, timeout: Double = 12, _ then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            guard let t = tab() else {
                return Date() > deadline ? then(false) : DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
            }
            t.evaluate(ready) { v in
                if v as? Bool == true { then(true) }
                else if Date() > deadline { then(false) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll) }
            }
        }
        poll()
    }

    func profileSignInScenario() {
        let cases = Self.signInCases
        profileSignInMain { [self] in
            check(c.profileSignIn === ProfileSignInCoordinator.shared, "profilesignin: every window uses the shared coordinator")
            check(ProfileSignInCoordinator.isSignIn(URL(string: "https://accounts.google.com/signin")!) &&
                  !ProfileSignInCoordinator.isSignIn(URL(string: "https://accounts.google.com.evil.example/signin")!),
                  "profilesignin: polling requires an actual sign-in tab")
        }
        if c.store.state.profiles.values.contains(where: { $0.name == cases[0].name }) { return profileSignInRelaunch(cases) }

        let chromium = ProcessInfo.processInfo.arguments.contains("--engine=chromium")
        if chromium {
            check(ProcessInfo.processInfo.arguments.contains { $0.contains("MAP *.airc-fixture.co.uk 127.0.0.1") },
                  "profilesignin: Chromium launched with --host-resolver-rules for the fixture hosts")
        }
        let fixture = SignInFixture(photos: ["alex@example.com": dir.appendingPathComponent("profilesignin-alex.png"),
                                             "blair@example.com": dir.appendingPathComponent("profilesignin-blair.png")])
        var ids: [String] = [], spaces: [String] = []
        step { [self] done in
            fixture.photos.values.forEach { writeMockPhoto(to: $0) }
            fixture.start { ok in
                self.check(ok, "profilesignin: the Google fixture starts on loopback")
                GoogleAccountProbe.testURL = fixture.listAccounts
                GoogleAccountProbe.testSignInURL = fixture.signIn
                done()
            }
        }
        profileSignInMain { [self] in
            do {
                for (i, k) in cases.enumerated() {
                    // As Create Profile does: the profile and its engine profile, then a Space using it.
                    let p = try c.profiles.createProfile(name: k.name, emoji: "🌱", color: nil)
                    let s = try c.store.createSpace(name: k.name, theme: .single(["7EB6D5", "9DC3AC", "E3B5A4", "B8A9E3"][i]), profileID: p.id)
                    ids.append(p.id); spaces.append(s.id)
                }
            } catch { check(false, "profilesignin: setup (\(error))") }
            check(ids.count == cases.count, "profilesignin: created a new profile and Space per case")
        }
        step { [self] done in c.profiles.loadAll(completion: done) }
        // WebKit: only the fixture's domain goes to the fixture (it never forwards anything).
        for i in cases.indices {
            step { [self] done in
                guard ids.indices.contains(i) else { return done() }
                c.profiles.whenLoaded(ids[i], { loaded in
                    if let w = loaded as? WebKitProfile {
                        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: fixture.port)!))
                        proxy.matchDomains = [SignInFixture.domain]
                        proxy.allowFailover = false
                        w.dataStore.proxyConfigurations = [proxy]
                    }
                    done()
                }, failed: { self.check(false, "profilesignin: case \(i)'s engine profile loads"); done() })
            }
        }
        signInFront()

        for (i, k) in cases.enumerated() {
            let tag = k.name
            let pid = { ids.indices.contains(i) ? ids[i] : "" }, sid = { spaces.indices.contains(i) ? spaces[i] : "" }
            var signInTab = ""
            // Second account: signed in on the web in this profile first (its cookie jar has u/0 already).
            if let first = k.before {
                var webTab = ""
                profileSignInMain { [self] in
                    c.switchToSpace(sid(), animated: false)
                    if let t = try? c.store.openTab(url: fixture.complete(first).absoluteString, inSpace: sid()) {
                        webTab = t.id
                        c.show(t.id, focus: false)
                    }
                }
                step { [self] done in
                    waitUntil({ self.c.store.tab(webTab).flatMap { URL(string: $0.url)?.host } == fixture.myAccountHost }, timeout: 12) {
                        self.check(self.c.store.tab(webTab).flatMap { URL(string: $0.url)?.host } == fixture.myAccountHost,
                                   "profilesignin \(tag): \(first) signed in on the web first")
                        done()
                    }
                }
            }
            profileSignInMain { [self] in
                c.switchToSpace(sid(), animated: false)
                c.reloadAll(animated: false)
                check(c.showsSignInCard(spaceID: sid()) && c.store.profile(pid())?.signInState == .created,
                      "profilesignin \(tag): the new profile's Space shows the Sign in card")
                let card = signInCard(sid())
                check(card != nil && card?.account == nil, "profilesignin \(tag): the card is drawn in Today, asking to sign in")
            }
            guard let email = k.signIn else {
                // ✕ before signing in: gone for good.
                signInPress(tag, sid, "Dismiss")
                profileSignInMain { [self] in
                    c.reloadAll(animated: false)
                    check(c.store.profile(pid())?.signInState == .dismissed && !c.showsSignInCard(spaceID: sid()) && signInCard(sid()) == nil,
                          "profilesignin \(tag): ✕ removes the card")
                    try? c.store.receiveGoogleSignIn(pid(), account: GoogleAccount(name: "Late", email: "late@example.com"), index: 0)
                    c.reloadAll(animated: false)
                    check(c.store.profile(pid())?.signInState == .dismissed && c.store.profile(pid())?.googleAccount == nil
                          && !c.showsSignInCard(spaceID: sid()), "profilesignin \(tag): a late account answer never shows it again")
                }
                continue
            }
            signInPress(tag, sid, AircSignInCopy.signIn)
            step { [self] done in
                waitUntil({ self.c.store.todayTabs(ofSpace: sid()).contains { $0.url == fixture.signIn.absoluteString } }, timeout: 5) {
                    let tab = self.c.store.todayTabs(ofSpace: sid()).first { $0.url == fixture.signIn.absoluteString }
                    signInTab = tab?.id ?? ""
                    self.check(tab?.profileID == pid() && self.c.store.profile(pid())?.signInState == .signingIn,
                               "profilesignin \(tag): Sign in opens Google's sign-in in that Space and profile")
                    done()
                }
            }
            // The probe's first answer is what was signed in before (nobody, or the web account).
            step { [self] done in
                waitUntil({ self.c.profileSignIn.baselineProfiles.contains(pid()) }, timeout: 12) {
                    let offered = MainActor.assumeIsolated { self.signInCard(sid())?.account != nil }
                    self.check(self.c.profileSignIn.baselineProfiles.contains(pid()) && self.c.store.profile(pid())?.signInState == .signingIn
                               && !offered,
                               "profilesignin \(tag): the profile's accounts before sign-in are read, nothing offered yet")
                    done()
                }
            }
            step { [self] done in
                let page = { self.c.engineTab(for: signInTab) }
                signInPage(page, until: "!!document.getElementById('\(email)')") { ok in
                    self.check(ok, "profilesignin \(tag): the fixture's sign-in page loads")
                    // The account's link: the fixture sets this profile's cookie and redirects to another host.
                    page()?.evaluate("document.getElementById('\(email)').click()") { _ in done() }
                }
            }
            step { [self] done in
                waitUntil({ self.c.store.profile(pid())?.signInState == .offered }, timeout: 20) {
                    let p = self.c.store.profile(pid())
                    self.check(p?.signInState == .offered && p?.googleAccount == email,
                               "profilesignin \(tag): sign-in completion is detected in that profile (\(p?.googleAccount ?? "none"))")
                    self.waitUntil({ GoogleAccountPhoto.cached(p?.googleAccountPhoto) != nil }, timeout: 5) { done() }
                }
            }
            profileSignInMain { [self] in
                guard let p = c.store.profile(pid()) else { return check(false, "profilesignin \(tag): profile") }
                c.reloadAll(animated: false)
                c.window.contentView?.layoutSubtreeIfNeeded()
                check(p.googleAccountName == fixture.names[email] && p.googleAccountPhoto == fixture.photos[email]?.absoluteString
                      && p.googleAccountIndex == k.index,
                      "profilesignin \(tag): the profile keeps the account's name, picture and u/\(k.index) (\(p.googleAccountIndex.map(String.init) ?? "nil"))")
                let indicator = signInFind(c.pageView(for: sid()), ProfileIndicatorView.self)
                check(indicator?.toolTip?.contains("\(fixture.names[email]!), \(email)") == true,
                      "profilesignin \(tag): the profile indicator names the account (\(indicator?.toolTip ?? "none"))")
                check(indicator?.avatarImage != nil && indicator?.avatarImage === GoogleAccountPhoto.avatar(p, size: 16)
                      && indicator?.avatarImage !== ProfileAvatarImage.initial(p, size: 16),
                      "profilesignin \(tag): the profile indicator shows the account's picture")
                let card = signInCard(sid())
                check(card?.account == email && card?.accountName == fixture.names[email] && card?.photo != nil
                      && card?.apps == "Gmail, Calendar and Drive",
                      "profilesignin \(tag): the card offers Gmail, Calendar and Drive for \(fixture.names[email]!) with their picture")
                check(c.store.favorites(ofProfile: pid()).isEmpty, "profilesignin \(tag): nothing is pinned before an answer")
            }
            signInPress(tag, sid, k.answer)
            profileSignInMain { [self] in
                c.reloadAll(animated: false)
                let added = k.answer == AircSignInCopy.add
                check(!c.showsSignInCard(spaceID: sid()) && signInCard(sid()) == nil
                      && c.store.profile(pid())?.signInState == (added ? .added : .declined),
                      "profilesignin \(tag): \(k.answer) removes the card")
                let urls = c.store.favorites(ofProfile: pid()).compactMap(\.savedURL)
                let want = added ? GoogleSuggestedFavorites.sites.map { GoogleSuggestedFavorites.url($0, email: email, index: k.index) } : []
                check(urls == want, "profilesignin \(tag): \(added ? "Add pins Gmail, Calendar and Drive as u/\(k.index)" : "Skip pins nothing") (\(urls))")
                let page = c.pageView(for: sid())
                check(c.store.favorites(ofProfile: pid()).allSatisfy { page?.tileView($0.id) != nil },
                      "profilesignin \(tag): the Space's Favorites row draws them")
                for (j, other) in ids.enumerated() where j > i {
                    check(c.store.favorites(ofProfile: other).isEmpty && c.store.profile(other)?.googleAccount == nil,
                          "profilesignin \(tag): another new profile stays untouched (\(cases[j].name))")
                }
                c.reloadAll(animated: false)
                check(!c.showsSignInCard(spaceID: sid()), "profilesignin \(tag): the offer isn't shown again")
            }
        }
        profileSignInMain { [self] in
            check(c.profileSignIn.pollingProfiles.isEmpty, "profilesignin: no profile is still polled once every card is answered")
            if let id = ids.last {
                let kept = c.store.profile(id)
                try? c.store.receiveGoogleSignIn(id, account: GoogleAccount(email: "late@example.com"), index: 0)
                check(c.store.profile(id)?.googleAccount == kept?.googleAccount, "profilesignin: a late answer after Add changes nothing")
            }
            try? c.store.flush()
            GoogleAccountProbe.testURL = nil
            GoogleAccountProbe.testSignInURL = nil
        }
        step { [self] done in
            var left = ids.count
            if left == 0 { fixture.stop(); return done() }
            for id in ids {
                c.profiles.whenLoaded(id, { loaded in
                    (loaded as? WebKitProfile)?.dataStore.proxyConfigurations = []
                    left -= 1
                    if left == 0 { fixture.stop(); done() }
                }, failed: { left -= 1; if left == 0 { fixture.stop(); done() } })
            }
        }
    }

    /// The second process: every answer, account and Favorite was kept; no card comes back.
    private func profileSignInRelaunch(_ cases: [SignInCase]) {
        profileSignInMain { [self] in
            for k in cases {
                guard let p = c.store.state.profiles.values.first(where: { $0.name == k.name }),
                      let s = c.store.spaces(usingProfile: p.id).first else {
                    check(false, "profilesignin relaunch: \(k.name) and its Space exist"); continue
                }
                let state: ProfileSignInState = k.signIn == nil ? .dismissed : k.answer == AircSignInCopy.add ? .added : .declined
                check(p.signInState == state && !c.showsSignInCard(spaceID: s.id), "profilesignin relaunch \(k.name): \(state.rawValue), no card")
                if let email = k.signIn {
                    check(p.googleAccount == email && p.googleAccountName == "Alex Example" && p.googleAccountIndex == k.index
                          && p.googleAccountPhoto?.hasSuffix("profilesignin-alex.png") == true,
                          "profilesignin relaunch \(k.name): the account, its name, picture address and u/\(k.index) are kept")
                }
                let urls = c.store.favorites(ofProfile: p.id).compactMap(\.savedURL)
                check(urls.count == (state == .added ? 3 : 0) && urls.allSatisfy { $0.contains("/u/\(k.index)/") && $0.contains("authuser=alex@example.com") },
                      "profilesignin relaunch \(k.name): its Favorites are kept (\(urls.count))")
            }
        }
    }

    func mkProfileSignInShot() {
        // Not in the snapshot folder: every image there becomes a marketing shot.
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("profilesignin-shot.png")
        profileSignInMain { [self] in
            writeMockPhoto(to: photo)
            guard let p = try? c.store.createProfile(name: "Studio", emoji: "🌱"),
                  let s = try? c.store.createSpace(name: "A fresh start", theme: .single("9DC3AC"), profileID: p.id) else { return }
            try? c.store.beginGoogleSignIn(p.id)
            try? c.store.receiveGoogleSignIn(p.id, account: GoogleAccount(name: "Alex Example", email: "alex@example.com",
                                                                          photoURL: photo.absoluteString), index: 0)
            _ = GoogleAccountPhoto.cached(photo.absoluteString)
            c.setSidebarWidth(280)
            c.switchToSpace(s.id, animated: false)
            c.reloadAll(animated: false)
        }
        wait(0.6)
        profileSignInMain { [self] in c.reloadAll(animated: false) }
        wait(0.3)
        mkWindowShot("profile-sign-in")
    }
}

/// Plays Google for the check on loopback: `accounts.<domain>/ServiceLogin` (one link per account),
/// `/complete?email=` (adds the account to this browser profile's cookie, then redirects to `myaccount.<domain>`) and
/// `/ListAccounts` (Google's answer shape, from the cookie, in sign-in order). Answers CONNECT for WebKit's proxy.
final class SignInFixture {
    static let domain = "airc-fixture.co.uk"
    let photos: [String: URL]
    let names = ["alex@example.com": "Alex Example", "blair@example.com": "Blair Example"]
    private let queue = DispatchQueue(label: "airc.profilesignin.fixture")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    var accountsHost: String { "accounts." + Self.domain }
    var myAccountHost: String { "myaccount." + Self.domain }

    init(photos: [String: URL]) { self.photos = photos }

    private func url(_ host: String, _ path: String) -> URL { URL(string: "http://\(host):\(port)\(path)")! }
    var listAccounts: URL { url(accountsHost, "/ListAccounts") }
    var signIn: URL { url(accountsHost, "/ServiceLogin") }
    func complete(_ email: String) -> URL { url(accountsHost, "/complete?email=" + email) }

    func start(_ ready: @escaping (Bool) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        guard let l = try? NWListener(using: parameters) else { return ready(false) }
        listener = l
        var answered = false
        l.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard !answered, let self else { return }
                switch state {
                case .ready: answered = true; self.port = l.port?.rawValue ?? 0; ready(self.port != 0)
                case .failed: answered = true; ready(false)
                default: break
                }
            }
        }
        l.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            connection.start(queue: self.queue)
            self.receive(connection, Data())
        }
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        photos.values.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func receive(_ connection: NWConnection, _ prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var bytes = prefix
            bytes.append(data ?? Data())
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || bytes.count > 65536 { connection.cancel() } else { self.receive(connection, bytes) }
                return
            }
            let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
            if head.hasPrefix("CONNECT ") {
                connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    self.receive(connection, Data(bytes[end.upperBound...]))
                })
                return
            }
            connection.send(content: self.respond(head), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func respond(_ head: String) -> Data {
        let lines = head.components(separatedBy: "\r\n")
        func header(_ name: String) -> String? {
            lines.dropFirst().first { $0.lowercased().hasPrefix(name + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let c = URLComponents(string: target.hasPrefix("/") ? "http://fixture" + target : target)
        let host = (header("host") ?? c?.host ?? "").split(separator: ":").first.map(String.init) ?? ""
        let path = c?.path ?? "/"
        let cookie = (header("cookie") ?? "").components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("SID=") }.map { String($0.dropFirst(4)) } ?? ""
        let accounts = cookie.split(separator: "+").map(String.init).filter { names[$0] != nil }
        var status = "200 OK", extra = "", body: String
        if host == accountsHost, path == "/ListAccounts" {
            let rows = accounts.enumerated().map { i, email in
                #"["gaia.l.a",1,"\#(names[email]!)","\#(email)","\#(photos[email]?.absoluteString ?? "")",1,1,0,null,1,"10000000000000000000\#(i)",null,null,null,null,1]"#
            }
            body = #"["gaia.l.a.r",[\#(rows.joined(separator: ","))]]"#
        } else if host == accountsHost, path == "/ServiceLogin" {
            body = "<title>Sign in</title><h1>Choose an account</h1>"
                + names.keys.sorted().map { "<p><a id='\($0)' href='/complete?email=\($0)'>\(names[$0]!)</a></p>" }.joined()
        } else if host == accountsHost, path == "/complete",
                  let email = c?.queryItems?.first(where: { $0.name == "email" })?.value, names[email] != nil {
            let now = accounts.contains(email) ? accounts : accounts + [email]
            status = "302 Found"
            extra = "Location: http://\(myAccountHost):\(port)/\r\nSet-Cookie: SID=\(now.joined(separator: "+")); Domain=\(Self.domain); Path=/; Max-Age=3600\r\n"
            body = ""
        } else {
            body = "<title>Account</title>Signed in"
        }
        let payload = Data(body.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\n"
            + "Cache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n"
        return Data(response.utf8) + payload
    }
}
#endif
