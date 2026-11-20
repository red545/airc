// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircDesign
import AircKit
import AppKit
import Network
import WebKit

/// ON-3 + SP-12: the journey after Create Profile (colour with a live preview → Sign in to Google in the new profile →
/// the account's picture and name → the card closes), its skip paths, and a sign-in from the sidebar card, all checked
/// for the avatar and account refreshing in the Space switcher (footer tooltip, Set Profile menu), the Space header's
/// profile chip and Settings › Profiles in the same process, without a relaunch.
/// Identity comes from profilesignin's loopback fixture (made-up users on airc-fixture.co.uk), never a real account.
/// Real clicks and keys need AIRC_REAL_KEYS=1, AIRC_UI_DEDICATED_SESSION=1 and the stable UI driver; without them the
/// clicks are posted to the app's queue and the log says so.
extension SnapshotRunner {
    private var journeyReal: Bool { signInReal }
    private func journeyCard() -> NSView? { c.profileJourney?.panel.hostingView ?? c.createProfilePanel?.hostingView }

    /// A click on the card's anchor once it stops moving: a real driver click when this run may, else posted.
    private func journeyClick(_ tag: String, _ anchor: String, _ host: @escaping () -> NSView? = { nil }) {
        step { [self] done in
            let deadline = Date().addingTimeInterval(2.5)
            var last: NSPoint?
            var stable = 0
            func settle() {
                c.window.contentView?.layoutSubtreeIfNeeded()
                let h = host() ?? journeyCard()
                let p = h.flatMap { anchorPoint(anchor, in: $0) }
                if let p, p == last { stable += 1 } else { stable = 0 }
                last = p
                if stable < 4, Date() < deadline { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: settle) }
                guard let h, let p, let w = h.window else {
                    check(false, "profilejourney \(tag): \(anchor) is on screen"); return done()
                }
                guard journeyReal else {
                    return click(at: p, in: w) { self.note("profilejourney \(tag): \(anchor) posted click (no real input in this run)"); done() }
                }
                let s = w.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
                guard NSApp.isActive, w.isKeyWindow, NSWindow.windowNumber(at: s, belowWindowWithWindowNumber: 0) == w.windowNumber else {
                    note("FAIL-ENV profilejourney \(tag): our window isn't the active key window under \(anchor) (active \(NSApp.isActive))")
                    return done()
                }
                UIDriverClient.run(["--click", String(Double(s.x)), String(Double(top - s.y))]) { ok, out in
                    if !ok { self.note("FAIL-ENV profilejourney \(tag): the driver's click on \(anchor) (\(out.prefix(200)))") }
                    else { self.note("profilejourney \(tag): \(anchor) real click") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: done)
                }
            }
            // Past the double-click interval since the last press.
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.1, execute: settle)
        }
    }

    /// Esc: a real key to this app when this run may, else posted to the key window.
    private func journeyEsc(_ tag: String) {
        step { [self] done in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                guard journeyReal else {
                    postKey("\u{1b}", keyCode: 53)
                    note("profilejourney \(tag): Esc posted (no real input in this run)")
                    return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
                UIDriverClient.press(["esc"], pid: getpid()) { ok, out in
                    self.note(ok ? "profilejourney \(tag): Esc real key (PID-targeted)" : "FAIL-ENV profilejourney \(tag): the driver's Esc (\(out.prefix(200)))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: done)
                }
            }
        }
    }

    /// The colour at `local` (`view`'s own coordinates) as drawn now.
    @MainActor private func journeyPixel(_ view: NSView, at local: NSPoint) -> NSColor? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / max(1, view.bounds.width), sy = CGFloat(rep.pixelsHigh) / max(1, view.bounds.height)
        let y = view.isFlipped ? local.y : view.bounds.height - local.y
        return rep.colorAt(x: Int(local.x * sx), y: Int(y * sy))?.usingColorSpace(.deviceRGB)
    }

    /// Whether the avatar anchored as `anchor` in `host` shows the fixture's picture (its blue-violet gradient), not
    /// the pastel initial of a warm profile colour. The pixel is read from the nearest view that draws it: the anchor's
    /// ancestors up to `host` (a SwiftUI ScrollView's content is drawn by a view of its own), then the window's layers.
    @MainActor private func journeyShowsPhoto(_ anchor: String, in host: NSView) -> (Bool, String) {
        guard let v = TestAnchors.view(anchor, in: host) else { return (false, "no \(anchor)") }
        var tried: [String] = []
        func judge(_ c: NSColor, _ how: String) -> (Bool, String)? {
            let s = String(format: "rgba %.2f %.2f %.2f %.2f via %@", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent, how)
            guard c.alphaComponent > 0.5 else { tried.append(s); return nil }
            return (c.blueComponent - c.redComponent > 0.2, s)
        }
        // A quarter in from the avatar's top left: the gradient, clear of the letter.
        let local = NSPoint(x: v.bounds.width * 0.3, y: v.isFlipped ? v.bounds.height * 0.3 : v.bounds.height * 0.7)
        var view: NSView? = v
        while let w = view {
            let p = w.convert(local, from: v)
            if w.bounds.contains(p), let c = journeyPixel(w, at: p), let r = judge(c, String(describing: type(of: w))) { return r }
            if w === host { break }
            view = w.superview
        }
        // The layer tree, as drawn (CALayer.render: rows come out bottom-up).
        if let root = host.window?.contentView?.superview, let layer = root.layer {
            let p = root.convert(local, from: v)
            let scale = host.window?.backingScaleFactor ?? 2
            let w = Int(root.bounds.width * scale), h = Int(root.bounds.height * scale)
            if w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                if let img = ctx.makeImage() {
                    let rep = NSBitmapImageRep(cgImage: img)
                    let yUp = root.isFlipped ? root.bounds.height - p.y : p.y
                    if let c = rep.colorAt(x: Int(p.x * scale), y: h - 1 - Int(yUp * scale))?.usingColorSpace(.deviceRGB),
                       let r = judge(c, "layer render") { return r }
                }
            }
        }
        return (false, "nothing drew it: " + tried.joined(separator: "; "))
    }

    /// The three places outside the card: the footer Space switcher (tooltip, Set Profile menu), the Space header's
    /// profile chip and Settings › Profiles.
    private func journeyRefreshChecks(_ tag: String, profileID: @escaping () -> String, spaceID: @escaping () -> String,
                                      name: String, email: String) {
        profileSignInMain { [self] in
            guard let p = c.store.profile(profileID()) else { return check(false, "profilejourney \(tag): profile") }
            c.window.contentView?.layoutSubtreeIfNeeded()
            let photo = ProfileAvatarImage.image(p, size: 16)
            check(GoogleAccountPhoto.photoAvatar(p, size: 16) != nil && photo !== ProfileAvatarImage.initial(p, size: 16),
                  "profilejourney \(tag): the account's picture is loaded for the profile")
            // Profile chip (Space header indicator).
            let chip = signInFind(c.pageView(for: spaceID()), ProfileIndicatorView.self)
            check(chip?.avatarImage === photo && chip?.toolTip?.contains("\(name), \(email)") == true,
                  "profilejourney \(tag): chip shows the account's picture and name (\(chip?.toolTip ?? "no chip"))")
            // Space switcher: the footer cell's tooltip, and the Set Profile menu (Space menu, chip, Manage Spaces).
            let cell = c.sidebar.footer.cells.first { $0.spaceID == spaceID() }
            check(cell?.toolTip == "\(c.store.space(spaceID())?.name ?? "") · \(p.name) (\(name))",
                  "profilejourney \(tag): Space switcher names the profile and account (\(cell?.toolTip ?? "no cell"))")
            let item = c.setProfileMenu(spaceID: spaceID(), current: p.id).items.first { $0.title == p.name }
            var subtitled = true
            if #available(macOS 14.4, *) { subtitled = item?.subtitle == email }
            check(item?.image === ProfileAvatarImage.image(p, size: 18) && item?.image !== ProfileAvatarImage.initial(p, size: 18) && subtitled,
                  "profilejourney \(tag): Set Profile › shows the account's picture and email")
            c.app?.showSettings(page: .profiles)
        }
        wait(0.8)
        profileSignInMain { [self] in
            // The new profile's section is below the fold: bring it into view before reading its pixels.
            guard let p = c.store.profile(profileID()), let host = c.app?.settingsWindow?.window.contentView else { return }
            host.layoutSubtreeIfNeeded()
            TestAnchors.view("settings.profile.avatar." + p.id, in: host)?.scrollToVisible(NSRect(x: 0, y: -40, width: 28, height: 108))
        }
        wait(0.5)
        profileSignInMain { [self] in
            guard let p = c.store.profile(profileID()), let w = c.app?.settingsWindow?.window, let host = w.contentView else {
                return check(false, "profilejourney \(tag): Settings › Profiles is open")
            }
            host.layoutSubtreeIfNeeded()
            check(p.googleAccountLine == "\(name) · \(email)"
                  && TestAnchors.view("settings.profile.account." + p.id, in: host) != nil,
                  "profilejourney \(tag): Settings › Profiles says “Signed in as \(name) · \(email)”")
            let (shows, how) = journeyShowsPhoto("settings.profile.avatar." + p.id, in: host)
            check(shows, "profilejourney \(tag): Settings › Profiles shows the account's picture (\(how))")
            w.orderOut(nil)
        }
    }

    func profileJourneyScenario() {
        let fixture = SignInFixture(photos: ["alex@example.com": dir.appendingPathComponent("profilejourney-alex.png"),
                                             "blair@example.com": dir.appendingPathComponent("profilejourney-blair.png")])
        if ProcessInfo.processInfo.arguments.contains("--engine=chromium") {
            run { [self] in
                check(ProcessInfo.processInfo.arguments.contains { $0.contains("MAP *.airc-fixture.co.uk 127.0.0.1") },
                      "profilejourney: Chromium launched with --host-resolver-rules for the fixture hosts")
            }
        }
        // A warm profile colour, so the pastel initial can't pass for the fixture's blue picture.
        let warm = AircProfileColor.choices.firstIndex { $0.red - $0.blue > 0.25 } ?? 0
        var spaces: [String] = [], originals: [SpaceTheme] = []
        step { [self] done in
            fixture.photos.values.forEach { writeMockPhoto(to: $0) }
            fixture.start { ok in
                self.check(ok, "profilejourney: the identity fixture starts on loopback")
                GoogleAccountProbe.testURL = fixture.listAccounts
                GoogleAccountProbe.testSignInURL = fixture.signIn
                ProfileJourney.enabledInChecks = true
                done()
            }
        }
        profileSignInMain { [self] in
            for (i, n) in ["Journey", "Journey Skip", "Journey Esc", "Sidebar"].enumerated() {
                if let s = try? c.store.createSpace(name: n, theme: .single(["9DC3AC", "E3B5A4", "B8A9E3", "7EB6D5"][i]),
                                                     profileID: c.store.selectedSpace.profileID) {
                    spaces.append(s.id); originals.append(s.theme)
                }
            }
            check(spaces.count == 4, "profilejourney: four Spaces in the default profile")
            c.reloadAll(animated: false)
        }
        signInFront()

        // WebKit: only the fixture's domain goes to the fixture (it never forwards anything).
        func route(_ pid: @escaping () -> String) {
            step { [self] done in
                c.profiles.whenLoaded(pid(), { loaded in
                    if let w = loaded as? WebKitProfile {
                        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: fixture.port)!))
                        proxy.matchDomains = [SignInFixture.domain]
                        proxy.allowFailover = false
                        w.dataStore.proxyConfigurations = [proxy]
                    }
                    done()
                }, failed: { self.check(false, "profilejourney: the new engine profile loads"); done() })
            }
        }

        /// Space menu → Set Profile › New Profile… for Space `i`, named `name`, to the journey's colour step.
        var made: [String: String] = [:]
        func create(_ tag: String, _ i: Int, _ name: String) {
            var spare: String?
            profileSignInMain { [self] in
                c.switchToSpace(spaces[i], animated: false)
                c.openCreateProfile(forSpace: spaces[i])
            }
            step { [self] done in
                // The warm spare engine profile (SP-11) is ready before Create.
                waitUntil({ self.c.createProfilePanel != nil && self.c.profiles.spareDirectory != nil }, timeout: 8) {
                    spare = self.c.profiles.spareDirectory
                    self.c.createProfilePanel?.model.name = name
                    self.c.createProfilePanel?.model.colorIndex = warm
                    done()
                }
            }
            journeyClick(tag, "profile.primary")
            step { [self] done in waitUntil({ self.c.createProfilePanel?.model.step == .spaces }, timeout: 3) { done() } }
            profileSignInMain { [self] in
                check(c.createProfilePanel?.model.chosen == [spaces[i]] && c.createProfilePanel?.model.dotSteps.count == 4,
                      "profilejourney \(tag): step 2 has the Space ticked and four steps in its dots")
            }
            journeyClick(tag, "profile.primary")
            step { [self] done in waitUntil({ self.c.profileJourney?.panel.model.step == .theme }, timeout: 3) { done() } }
            profileSignInMain { [self] in
                let p = c.store.state.profiles.values.first { $0.name == name }
                made[tag] = p?.id
                check(p != nil && c.store.space(spaces[i])?.profileID == p?.id && p?.engineDirectory == spare,
                      "profilejourney \(tag): Create Profile made \(name) on the warm spare and moved the Space to it")
                check(c.createProfilePanel == nil && c.profileJourney?.panel.superview === c.root && c.profileJourney?.panel.model.step == .theme
                      && c.currentSpaceID == spaces[i],
                      "profilejourney \(tag): the same card goes on to the colour step over its Space")
            }
        }
        let sid: (Int) -> () -> String = { i in { spaces.indices.contains(i) ? spaces[i] : "" } }

        // 1. The whole journey: colour (live) → Next → Sign in to Google → the account → closes by itself.
        let ocean = DesignTheme.preset("ocean")!.model
        create("journey", 0, "Journey")
        route { made["journey"] ?? "" }
        journeyClick("journey", "journey.theme.ocean")
        profileSignInMain { [self] in
            guard let s = c.store.space(spaces[0]), let j = c.profileJourney else { return check(false, "profilejourney journey: still open") }
            check(s.theme == ocean && j.panel.model.themeID == "ocean", "profilejourney journey: a colour is applied to the Space at once")
            check(c.currentPalette == c.palette(for: s) && c.currentPalette.isDark && j.panel.model.ui == c.currentPalette.resolved,
                  "profilejourney journey: the window and the card show it live (preview)")
        }
        journeyClick("journey", "journey.theme.next")
        step { [self] done in waitUntil({ self.c.profileJourney?.panel.model.step == .signIn }, timeout: 3) { done() } }
        profileSignInMain { [self] in
            check(c.profileJourney?.panel.model.step == .signIn && c.store.space(spaces[0])?.theme == ocean,
                  "profilejourney journey: Next keeps the colour and asks to sign in")
        }
        journeyClick("journey", "journey.signin.google")
        var tabID = ""
        step { [self] done in
            waitUntil({ self.c.store.todayTabs(ofSpace: spaces[0]).contains { $0.url == fixture.signIn.absoluteString }
                        && self.c.profileJourney?.panel.superview == nil }, timeout: 5) {
                let tab = self.c.store.todayTabs(ofSpace: spaces[0]).first { $0.url == fixture.signIn.absoluteString }
                tabID = tab?.id ?? ""
                self.check(tab?.profileID == made["journey"] && self.c.store.profile(made["journey"] ?? "")?.signInState == .signingIn
                           && self.c.profileJourney?.waitingForSignIn == true && self.c.profileJourney?.panel.superview == nil,
                           "profilejourney journey: Sign in to Google opens the sign-in page in the new profile, the card steps aside")
                done()
            }
        }
        step { [self] done in
            waitUntil({ self.c.profileSignIn.baselineProfiles.contains(made["journey"] ?? "") }, timeout: 12) {
                self.check(self.c.profileSignIn.baselineProfiles.contains(made["journey"] ?? ""), "profilejourney journey: the probe read the empty profile first")
                done()
            }
        }
        step { [self] done in
            let page = { self.c.engineTab(for: tabID) }
            signInPage(page, until: "!!document.getElementById('alex@example.com')") { ok in
                self.check(ok, "profilejourney journey: the fixture's sign-in page loads")
                page()?.evaluate("document.getElementById('alex@example.com').click()") { _ in done() }
            }
        }
        step { [self] done in
            waitUntil({ self.c.profileJourney?.panel.model.step == .signedIn && self.c.profileJourney?.panel.model.accountPhoto != nil }, timeout: 20) {
                let m = self.c.profileJourney?.panel.model
                self.check(m?.step == .signedIn && m?.accountName == "Alex Example" && m?.accountEmail == "alex@example.com"
                           && self.c.profileJourney?.panel.superview === self.c.root,
                           "profilejourney journey: the card comes back with the account's name (\(m?.accountName ?? "none"))")
                self.check(m?.accountPhoto != nil, "profilejourney journey: … and its picture")
                done()
            }
        }
        wait(0.3)
        profileSignInMain { [self] in
            guard let card = journeyCard() else { return check(false, "profilejourney journey: the signed-in card") }
            card.layoutSubtreeIfNeeded()
            let (shows, how) = journeyShowsPhoto("journey.account.avatar", in: card)
            check(shows, "profilejourney journey: the card draws the account's picture (\(how))")
        }
        journeyRefreshChecks("journey", profileID: { made["journey"] ?? "" }, spaceID: sid(0), name: "Alex Example", email: "alex@example.com")
        step { [self] done in
            // It closes by itself (ProfileJourney.autoClose), with nothing pressed.
            waitUntil({ self.c.profileJourney == nil }, timeout: ProfileJourney.autoClose + 3) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.check(self.c.profileJourney == nil && !self.c.root.subviews.contains { $0 is CreateProfilePanelHost },
                               "profilejourney journey: the card closes by itself")
                    self.check(self.c.store.profile(made["journey"] ?? "")?.signInState == .offered && self.signInCard(spaces[0])?.account == "alex@example.com",
                               "profilejourney journey: the sidebar card goes on to offer \(GoogleSuggestedFavorites.names) (Arc's follow-up)")
                    done()
                }
            }
        }

        // 2. Skip with clicks: a previewed colour is put back, Skip on sign-in closes, the sidebar still invites.
        create("skip", 1, "Journey Skip")
        journeyClick("skip", "journey.theme.grape")
        profileSignInMain { [self] in
            check(c.store.space(spaces[1])?.theme == DesignTheme.preset("grape")!.model, "profilejourney skip: the previewed colour shows")
        }
        journeyClick("skip", "journey.theme.skip")
        step { [self] done in waitUntil({ self.c.profileJourney?.panel.model.step == .signIn }, timeout: 3) { done() } }
        profileSignInMain { [self] in
            check(c.store.space(spaces[1])?.theme == originals[1], "profilejourney skip: Skip puts the Space's colour back")
        }
        journeyClick("skip", "journey.signin.skip")
        step { [self] done in waitUntil({ self.c.profileJourney == nil }, timeout: 3) { done() } }
        profileSignInMain { [self] in
            let pid = made["skip"] ?? ""
            c.reloadAll(animated: false)
            check(c.profileJourney == nil && c.store.profile(pid)?.signInState == .created && c.store.profile(pid)?.googleAccount == nil
                  && c.store.todayTabs(ofSpace: spaces[1]).isEmpty && c.showsSignInCard(spaceID: spaces[1]),
                  "profilejourney skip: Skip closes the card, opens nothing, and the sidebar still offers Sign in")
        }

        // 3. Esc twice: the colour step's Esc skips it (colour put back), the sign-in step's closes.
        create("esc", 2, "Journey Esc")
        journeyClick("esc", "journey.theme.forest")
        journeyEsc("esc")
        step { [self] done in waitUntil({ self.c.profileJourney?.panel.model.step == .signIn }, timeout: 3) { done() } }
        profileSignInMain { [self] in
            check(c.profileJourney?.panel.model.step == .signIn && c.store.space(spaces[2])?.theme == originals[2],
                  "profilejourney esc: Esc on the colour step skips it and puts the colour back")
        }
        journeyEsc("esc")
        step { [self] done in waitUntil({ self.c.profileJourney == nil }, timeout: 3) { done() } }
        profileSignInMain { [self] in
            check(c.profileJourney == nil && c.store.profile(made["esc"] ?? "")?.signInState == .created,
                  "profilejourney esc: Esc on the sign-in step closes the card")
        }

        // 4. SP-12 without the journey: the sidebar card's Sign in, then the same refresh everywhere.
        var sidebarProfile = ""
        profileSignInMain { [self] in
            do {
                let p = try c.profiles.createProfile(name: "Sidebar", emoji: "🌱", color: RGBA(AircProfileColor.choices[warm]))
                sidebarProfile = p.id
                _ = try c.store.setProfile(ofSpace: spaces[3], to: p.id)
            } catch { check(false, "profilejourney sidebar: setup (\(error))") }
        }
        step { [self] done in c.profiles.loadAll(completion: done) }
        route { sidebarProfile }
        profileSignInMain { [self] in
            c.switchToSpace(spaces[3], animated: false)
            c.reloadAll(animated: false)
            check(c.showsSignInCard(spaceID: spaces[3]) && c.profileJourney == nil, "profilejourney sidebar: the new profile's Space shows the Sign in card")
        }
        signInPress("profilejourney sidebar", sid(3), AircSignInCopy.signIn)
        var sideTab = ""
        step { [self] done in
            waitUntil({ self.c.store.todayTabs(ofSpace: spaces[3]).contains { $0.url == fixture.signIn.absoluteString } }, timeout: 5) {
                sideTab = self.c.store.todayTabs(ofSpace: spaces[3]).first { $0.url == fixture.signIn.absoluteString }?.id ?? ""
                self.waitUntil({ self.c.profileSignIn.baselineProfiles.contains(sidebarProfile) }, timeout: 12) { done() }
            }
        }
        step { [self] done in
            let page = { self.c.engineTab(for: sideTab) }
            signInPage(page, until: "!!document.getElementById('blair@example.com')") { ok in
                self.check(ok, "profilejourney sidebar: the fixture's sign-in page loads")
                page()?.evaluate("document.getElementById('blair@example.com').click()") { _ in done() }
            }
        }
        step { [self] done in
            waitUntil({ self.c.store.profile(sidebarProfile)?.signInState == .offered
                        && GoogleAccountPhoto.cached(self.c.store.profile(sidebarProfile)?.googleAccountPhoto) != nil }, timeout: 20) {
                self.check(self.c.store.profile(sidebarProfile)?.googleAccount == "blair@example.com",
                           "profilejourney sidebar: the sign-in is detected in that profile (onboarding's probe)")
                done()
            }
        }
        wait(0.3)
        journeyRefreshChecks("sidebar", profileID: { sidebarProfile }, spaceID: sid(3), name: "Blair Example", email: "blair@example.com")
        profileSignInMain { [self] in
            check(signInCard(spaces[3])?.account == "blair@example.com" && signInCard(spaces[3])?.apps == GoogleSuggestedFavorites.names,
                  "profilejourney sidebar: the card offers \(GoogleSuggestedFavorites.names) for the account (Arc's follow-up)")
            check(c.profileJourney == nil, "profilejourney sidebar: no journey card for a sidebar sign-in")
        }

        // Clean up: the fixture, its routes, and the journey switch.
        profileSignInMain { [self] in
            ProfileJourney.enabledInChecks = false
            GoogleAccountProbe.testURL = nil
            GoogleAccountProbe.testSignInURL = nil
            try? c.store.flush()
        }
        step { [self] done in
            let ids = Array(made.values) + [sidebarProfile]
            var left = ids.count
            for id in ids {
                c.profiles.whenLoaded(id, { loaded in
                    (loaded as? WebKitProfile)?.dataStore.proxyConfigurations = []
                    left -= 1
                    if left == 0 { fixture.stop(); done() }
                }, failed: { left -= 1; if left == 0 { fixture.stop(); done() } })
            }
        }
    }

    /// Marketing (part profilesignin): the journey's colour step and its signed-in card, on a synthetic account.
    func mkProfileJourneyShots() {
        // Not in the snapshot folder: every image there becomes a marketing shot.
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("profilejourney-shot.png")
        profileSignInMain { [self] in
            writeMockPhoto(to: photo)
            ProfileJourney.enabledInChecks = true
            ProfileJourney.autoClose = 600
            guard let s = try? c.store.createSpace(name: "Side project", icon: .emoji("🧪"), theme: .single("E3B5A4"),
                                                   profileID: c.store.selectedSpace.profileID) else { return }
            c.setSidebarWidth(280)
            c.switchToSpace(s.id, animated: false)
            c.reloadAll(animated: false)
            c.openCreateProfile(forSpace: s.id)
            c.createProfilePanel?.model.name = "Freelance"
            c.createProfilePanel?.model.emoji = "🧪"
            c.createProfilePanel?.model.onCreate?()
        }
        wait(0.6)
        profileSignInMain { [self] in
            if let lilac = DesignTheme.presets.first(where: { $0.id == "lilac" }) { c.profileJourney?.panel.model.onThemePick?(lilac) }
        }
        wait(0.8)
        mkWindowShot("profile-journey-colour")
        profileSignInMain { [self] in
            guard let j = c.profileJourney else { return note("marketing: MISSING profile-journey: no journey") }
            try? c.store.beginGoogleSignIn(j.profileID)
            try? c.store.receiveGoogleSignIn(j.profileID, account: GoogleAccount(name: "Alex Example", email: "alex@example.com",
                                                                                  photoURL: photo.absoluteString), index: 0)
            _ = GoogleAccountPhoto.cached(photo.absoluteString)
            j.waitingForSignIn = true
            NotificationCenter.default.post(name: ProfileSignInCoordinator.didSignIn, object: j.profileID)
        }
        wait(0.8)
        profileSignInMain { [self] in c.reloadAll(animated: false) }
        wait(0.3)
        mkWindowShot("profile-journey-signed-in")
        profileSignInMain { [self] in
            c.endProfileJourney(revert: false)
            ProfileJourney.enabledInChecks = false
            ProfileJourney.autoClose = 2.4
        }
    }
}
#endif
