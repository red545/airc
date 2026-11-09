// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircDesign
import AircKit
import AppKit

extension SnapshotRunner {
    private func profileSignInMain(_ action: @escaping @MainActor () -> Void) {
        run { MainActor.assumeIsolated { action() } }
    }

    /// Run twice on the same scratch data: the second process verifies persisted choices without network.
    func profileSignInScenario() {
        profileSignInMain { [self] in
            check(c.profileSignIn === ProfileSignInCoordinator.shared, "profilesignin: every window uses the shared coordinator")
            check(ProfileSignInCoordinator.isSignIn(URL(string: "https://accounts.google.com/signin")!) &&
                  !ProfileSignInCoordinator.isSignIn(URL(string: "https://accounts.google.com.evil.example/signin")!),
                  "profilesignin: polling requires an actual sign-in tab")
        }
        let names = ["Sign-in Add", "Sign-in Decline", "Sign-in Dismiss"]
        if c.store.state.profiles.values.contains(where: { $0.name == names[0] }) {
            profileSignInMain { [self] in
                for (name, state) in zip(names, [ProfileSignInState.added, .declined, .dismissed]) {
                    guard let p = c.store.state.profiles.values.first(where: { $0.name == name }),
                          let s = c.store.spaces(usingProfile: p.id).first else {
                        check(false, "profilesignin: persisted profile and Space exist"); continue
                    }
                    check(p.signInState == state && !c.showsSignInCard(spaceID: s.id), "profilesignin: choice survives process relaunch")
                    check(c.store.favorites(ofProfile: p.id).count == (state == .added ? 2 : 0), "profilesignin: Favorites survive process relaunch")
                }
            }
            return
        }
        let mock = AccountMock(photo: dir.appendingPathComponent("profilesignin-photo.png"))
        startAccountMock(mock, "profilesignin")
        // Each profile becomes signed in only when its cross-host destination is requested.
        // Merely changing the probe URL before navigating can offer the card before the redirect commits.
        var redirectServers: [LocalPageServer] = []
        var signInURLs: [URL] = []
        for _ in 0..<2 {
            step { [self] done in
                guard let server = LocalPageServer(pages: [:]) else {
                    check(false, "profilesignin: redirect fixture starts"); return done()
                }
                var signedIn = false // accessed only on this server's queue
                server.handler = { path in
                    if path == "/complete" {
                        signedIn = true
                        return LocalPageServer.Page(body: "<title>Signed in</title>Complete")
                    }
                    guard path == "/ListAccounts" else { return nil }
                    return LocalPageServer.Page(body: signedIn ? mock.account : #"["gaia.l.a.r",[]]"#)
                }
                redirectServers.append(server)
                server.start { port in
                    if let port { signInURLs.append(URL(string: "http://127.0.0.1:\(port)/ListAccounts")!) }
                    done()
                }
            }
        }
        var ids: [String] = [], spaces: [String] = []
        var signInTabs: [String] = []
        func find<T: NSView>(_ root: NSView, _: T.Type) -> T? {
            if let v = root as? T { return v }
            return root.subviews.lazy.compactMap { find($0, T.self) }.first
        }
        profileSignInMain { [self] in
            do {
                for name in names {
                    let p = try c.store.createProfile(name: name, emoji: "🌱")
                    let s = try c.store.createSpace(name: name, theme: .single("7EB6D5"), profileID: p.id)
                    ids.append(p.id); spaces.append(s.id)
                }
                check(ids.count == 3, "profilesignin: created independent profiles")
            } catch { check(false, "profilesignin: setup") }
        }
        // Store fixtures bypass the ProfileHost creation flow, so load their engine profiles before
        // pressing Sign In. Otherwise show() has no profile and no page exists to navigate.
        step { [self] done in c.profiles.loadAll(completion: done) }
        for index in 0..<3 {
            profileSignInMain { [self] in
                guard spaces.count == 3, signInURLs.count == 2 else { return }
                GoogleAccountProbe.testURL = signInURLs.indices.contains(index) ? signInURLs[index] : mock.signedOut
                c.switchToSpace(spaces[index], animated: false)
                c.reloadAll(animated: false)
                check(c.showsSignInCard(spaceID: spaces[index]), "profilesignin: new profile shows sign-in card")
                let card = c.pageView(for: spaces[index]).flatMap { find($0, AircSignInCardView.self) }
                check(card != nil, "profilesignin: card is drawn in Today")
                if index == 2 { card?.onDismiss?() } else { card?.onSignIn() }
            }
            if index == 2 { continue }
            wait(1)
            profileSignInMain { [self] in
                guard spaces.count == 3, signInURLs.count == 2 else { return }
                check(c.showsSignInCard(spaceID: spaces[index]) && c.store.profile(ids[index])?.signInState == .signingIn,
                      "profilesignin: signed-out answer leaves card available with sign-in tab open")
                check(c.store.todayTabs(ofSpace: spaces[index]).contains { $0.profileID == ids[index] && $0.url == signInURLs[index].absoluteString },
                      "profilesignin: sign-in opens in the intended Space and profile")
                guard let tab = c.store.todayTabs(ofSpace: spaces[index]).first(where: { $0.url == signInURLs[index].absoluteString }),
                      let signedOut = GoogleAccountProbe.testURL else { return check(false, "profilesignin: sign-in tab available for redirect") }
                signInTabs.append(tab.id)
                var redirect = URLComponents(url: signedOut, resolvingAgainstBaseURL: false)!
                redirect.host = "localhost"
                redirect.path = "/complete"
                // Same loopback fixture, another host: as Google redirects to myaccount or continue.
                guard let page = c.engineTab(for: tab.id) else {
                    return check(false, "profilesignin: sign-in has a live page for redirect")
                }
                page.load(redirect.url!)
            }
            step { [self] done in
                waitUntil({
                    guard ids.count == 3, signInTabs.indices.contains(index) else { return false }
                    return self.c.store.profile(ids[index])?.signInState == .offered
                        && self.c.store.tab(signInTabs[index]).flatMap { URL(string: $0.url) }?.host == "localhost"
                }, timeout: 15) { done() }
            }
            profileSignInMain { [self] in
                guard spaces.count == 3, let p = c.store.profile(ids[index]) else { return }
                c.reloadAll(animated: false)
                let redirected = signInTabs.indices.contains(index) ? c.store.tab(signInTabs[index]).flatMap { URL(string: $0.url) } : nil
                check(redirected?.host == "localhost" && redirected?.path == "/complete",
                      "profilesignin: sign-in tab navigates to a different host")
                check(p.googleAccount == "alex@example.com" && p.signInState == .offered,
                      "profilesignin: shared probe detects account after sign-in tab redirects")
                let indicator = c.pageView(for: spaces[index]).flatMap { find($0, ProfileIndicatorView.self) }
                check(indicator?.toolTip?.contains("alex@example.com") == true, "profilesignin: indicator tooltip shows account locally")
                check(ProfileAvatarImage.image(p, size: 16) === ProfileAvatarImage.image(emoji: "", name: "alex@example.com", color: p.color.aircColor, size: 16),
                      "profilesignin: avatar uses account initial instead of profile emoji")
                let card = c.pageView(for: spaces[index]).flatMap { find($0, AircSignInCardView.self) }
                check(card?.account == "alex@example.com", "profilesignin: card offers Favorites for detected account")
                if index == 0 { card?.onSignIn() } else { card?.onNotNow() }
                check(!c.showsSignInCard(spaceID: spaces[index]), "profilesignin: answering removes card")
                let favorites = c.store.favorites(ofProfile: ids[index])
                check(favorites.count == (index == 0 ? 2 : 0), "profilesignin: Add pins two and No thanks pins none")
                if index == 0 {
                    check(favorites.allSatisfy { URLComponents(string: $0.savedURL ?? "")?.queryItems?.first?.value == "alex@example.com" },
                          "profilesignin: Favorites target the detected account")
                    check(c.store.favorites(ofProfile: ids[1]).isEmpty, "profilesignin: other profile stays untouched")
                }
            }
        }
        profileSignInMain { [self] in
            if let id = ids.last {
                try? c.store.beginGoogleSignIn(id)
                c.profileSignIn.refresh()
                check(!c.profileSignIn.pollingProfiles.contains(id), "profilesignin: a pending card without a sign-in tab never polls")
                try? c.store.finishGoogleSignIn(id, choice: .dismissed)
            }
            try? c.store.flush()
            GoogleAccountProbe.testURL = nil
            redirectServers.forEach { $0.stop() }
            mock.stop()
        }
    }

    func mkProfileSignInShot() {
        profileSignInMain { [self] in
            guard let p = try? c.store.createProfile(name: "Studio", emoji: "🌱"),
                  let s = try? c.store.createSpace(name: "A fresh start", theme: .single("9DC3AC"), profileID: p.id) else { return }
            try? c.store.beginGoogleSignIn(p.id)
            try? c.store.receiveGoogleSignIn(p.id, accounts: [GoogleAccount(name: "Alex Example", email: "alex@example.com")])
            c.setSidebarWidth(280)
            c.switchToSpace(s.id, animated: false)
            c.reloadAll(animated: false)
        }
        wait(0.6)
        mkWindowShot("profile-sign-in")
    }
}
#endif
