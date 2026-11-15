// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircImport
import AircKit
import AppKit
import Network

/// `--script pwmanager`: onboarding's password manager step (2b) on a synthetic Arc tree and a synthetic home folder.
/// Never the owner's Arc, Applications or Keychain; installs only a generated CRX (AIRC_EXTENSION_FIXTURE, Chromium).
enum PasswordManagerFixture {
    /// 1Password's Web Store ID: what Arc's extension list holds in the synthetic tree.
    static let onePassword = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    static func write(arc root: URL) throws {
        let fm = FileManager.default
        func json(_ path: String, _ value: Any) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        let spaces: [[String: Any]] = [
            ["id": "pm-personal", "title": "Personal", "profile": ["default": [:]], "containerIDs": []],
            ["id": "pm-work", "title": "Work", "profile": ["custom": ["_0": ["directoryBasename": "Profile 1"]]], "containerIDs": []],
        ]
        try json("StorableSidebar.json", ["version": 1, "sidebar": ["containers": [["global": [:]], ["spaces": spaces, "items": []]]]])
        for p in ["Default", "Profile 1"] {
            var settings: [String: Any] = [:]
            if p == "Default" {
                settings[onePassword] = ["manifest": ["name": "1Password – Password Manager", "version": "8"], "path": onePassword + "/8_0",
                                         "location": 1, "state": 1]
            }
            try json("User Data/\(p)/Preferences", ["extensions": ["settings": settings]])
        }
    }
}

extension SnapshotRunner {
    func passwordManagerScenario() {
        let root = dir.appendingPathComponent("pm-synthetic")
        let arc = root.appendingPathComponent("arc"), home = root.appendingPathComponent("home")
        let chromium = app?.engine.supportsExtensions == true
        var server: PasswordManagerStoreServer?
        var imported: [String] = []
        var before: [String: Bool?] = [:]
        let fixture = ProcessInfo.processInfo.environment["AIRC_EXTENSION_FIXTURE"]
        let fixtureID = fixture.flatMap { try? String(contentsOfFile: $0 + "/id.txt", encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func offered(_ pid: String) -> Bool? {
            guard let app, let ep = app.profiles.engineProfile(for: pid) else { return nil }
            return app.engine.passwordsOffered(for: ep)
        }
        func installed(_ pid: String, _ id: String?) -> Bool {
            guard let app, let id, let ep = app.profiles.engineProfile(for: pid) else { return false }
            return app.engine.installedExtensions(for: ep).contains { $0["id"] as? String == id }
        }

        func cleanUp() {
            BrowserImportLocator.testHome = nil
            OnboardingController.testArcDirectory = nil
            app?.settingsWindow?.window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
        }

        // 1. Arc's extension list preselects (no app in the synthetic Applications).
        run { [self] in
            do {
                try PasswordManagerFixture.write(arc: arc)
                try FileManager.default.createDirectory(at: home.appendingPathComponent("Applications"), withIntermediateDirectories: true)
            } catch { check(false, "pwmanager: synthetic Arc tree and home written") }
            BrowserImportLocator.testHome = home
            OnboardingController.testArcDirectory = arc
            note("pwmanager: engine supports extensions: \(chromium)")
            app?.startOnboarding(mode: .rerun, atImport: true)
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.hasArc == true }, timeout: 30, then: done) }
        run { [self] in
            guard let m = app?.onboarding?.model else { return check(false, "pwmanager: onboarding open") }
            m.includeLogins = false
            m.onImportEverything?()
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30, then: done) }
        run { [self] in
            guard let m = app?.onboarding?.model, let r = m.result else { return check(false, "pwmanager: imported") }
            imported = m.profileRows.compactMap { r.profileIDs[$0.id] }
            check(imported.count == 2, "pwmanager: two synthetic Arc profiles imported (\(imported.count))")
            check(ArcExtensionChecklist.shared.rows.contains { $0.extensionInfo.id == PasswordManagerFixture.onePassword },
                  "pwmanager: Arc's checklist found 1Password")
            check(m.step == .accounts, "pwmanager: import goes on to the accounts (\(m.step))")
            m.onNext?()
        }
        wait(0.6)
        run { [self] in
            guard let m = app?.onboarding?.model else { return }
            check(m.step == .passwordManager, "pwmanager: the step follows the accounts when logins are left out (\(m.step))")
            check(m.pmChoice == "1password" && m.pmHint == .arc("1Password"),
                  "pwmanager: Arc's 1Password extension preselects 1Password (\(m.pmChoice ?? "nil"), \(String(describing: m.pmHint)))")
            check(m.pmChosenProfiles == Set(imported), "pwmanager: the profiles the import made are chosen by default")
            check(m.pmTurnOffSaving, "pwmanager: turning off Airc's offer to save passwords is on by default")
            check(m.extensionsAvailable == chromium, "pwmanager: extensions available only on Chromium")
            check(TestAnchors.frames["onboarding.pm.grid"] != nil && TestAnchors.frames["onboarding.pm.choice.airc"] != nil,
                  "pwmanager: every choice and Airc's own on the step")
        }
        step { [self] done in
            guard let w = app?.onboarding?.window else { return done() }
            captureWindow(w, name: "pwmanager-1-preselected-\(chromium ? "chromium" : "webkit")", rounded: 24, done)
        }
        // Back returns to the accounts, forward again keeps the choice.
        run { [self] in app?.onboarding?.model.onBack?() }
        wait(0.5)
        run { [self] in
            guard let m = app?.onboarding?.model else { return }
            check(m.step == .accounts, "pwmanager: Back goes to the accounts (\(m.step))")
            m.onNext?()
        }
        wait(0.5)
        // 2. Not now: no side effects, on to the colours.
        run { [self] in
            guard let app, let m = app.onboarding?.model else { return }
            for p in app.store.orderedProfiles { before[p.id] = offered(p.id) }
            check(m.step == .passwordManager && m.pmChoice == "1password", "pwmanager: the choice survives Back")
            app.onboarding?.model.onPasswordManagerNotNow?()
        }
        wait(0.6)
        run { [self] in
            guard let app, let m = app.onboarding?.model else { return }
            check(m.step == .theme && m.pmOutcome == .skipped, "pwmanager: Not now goes on to the colours (\(m.step))")
            let same = app.store.orderedProfiles.allSatisfy { offered($0.id) == before[$0.id] ?? nil }
            check(same && !imported.contains { installed($0, PasswordManagerFixture.onePassword) || installed($0, fixtureID) },
                  "pwmanager: Not now installs nothing and changes no profile's save offer")
            m.onBack?()
            check(m.step == .passwordManager, "pwmanager: Back from the colours returns to the step")
            app.onboarding?.requestClose()
        }
        wait(0.8)

        // 3. A Mac app in Applications wins over Arc's list; opened again from Settings → Import.
        run { [self] in
            check(app?.onboarding == nil, "pwmanager: the re-run closed")
            try? FileManager.default.createDirectory(at: home.appendingPathComponent("Applications/Bitwarden.app"), withIntermediateDirectories: true)
            TestAnchors.frames["settings.pm.choose"] = nil
            app?.showSettings(page: .importing)
        }
        wait(1.0)
        step { [self] done in
            guard let v = app?.settingsWindow?.window.contentView else { check(false, "pwmanager: Settings open"); return done() }
            let button = TestAnchors.view("settings.pm.choose", in: v)
            check(button != nil, "pwmanager: Settings → Import offers the step again")
            // The section is below the fold: scroll it into view, as a person would, then click.
            button?.scrollToVisible(button!.bounds)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.clickAnchor("settings.pm.choose", in: v, done) }
        }
        wait(1.0)
        run { [self] in
            check(app?.onboarding?.model.step == .passwordManager, "pwmanager: Choose… in Settings opens the step (\(TestAnchors.lastHit["settings.pm.choose"] ?? "-"))")
            // Keep checking the rest even if the click missed.
            if app?.onboarding == nil { app?.startOnboarding(mode: .rerun, atPasswordManager: true) }
        }
        wait(0.6)
        run { [self] in
            guard let m = app?.onboarding?.model else { return check(false, "pwmanager: the step is open") }
            check(m.step == .passwordManager, "pwmanager: Settings opens straight on the step (\(m.step))")
            check(m.pmChoice == "bitwarden" && m.pmHint == .app("Bitwarden.app"),
                  "pwmanager: Bitwarden.app in Applications preselects Bitwarden (\(m.pmChoice ?? "nil"))")
            check(m.pmChosenProfiles == Set(app!.store.orderedProfiles.map(\.id)), "pwmanager: from Settings, every profile is chosen")
            if !chromium {
                check(!m.extensionsAvailable, "pwmanager: WebKit has no extensions")
                m.onPasswordManagerInstall?()
                check(m.pmResults == nil && !m.pmInstalling, "pwmanager: WebKit never tries to install an extension")
            }
        }
        step { [self] done in
            guard let w = app?.onboarding?.window else { return done() }
            captureWindow(w, name: "pwmanager-2-settings-\(chromium ? "chromium" : "webkit")", rounded: 24, done)
        }

        if !chromium {
            // WebKit: Airc's own is the one that works; it closes the Settings re-run.
            run { [self] in
                guard let m = app?.onboarding?.model else { return }
                m.pmChoice = "airc"
                m.onPasswordManagerInstall?()
                check(m.pmOutcome == .builtin, "pwmanager: Airc's own needs nothing installed")
            }
            wait(0.8)
            run { [self] in
                check(app?.onboarding == nil, "pwmanager: leaving the step opened from Settings closes it")
                cleanUp()
            }
            return
        }

        // 4. Chromium: 1Password (the generated CRX stands in) into two of the three profiles; one review accepted, one
        // declined. Results per profile, the save offer off only where it went in, the declined one opens its store page.
        #if canImport(AircCore)
        guard let fixture, let fixtureID else {
            run { [self] in check(false, "pwmanager: Chromium needs AIRC_EXTENSION_FIXTURE (engine/host/extension_fixture.py)"); cleanUp() }
            return
        }
        var answers: [Bool] = [true, false]
        var reviews = 0
        run { [self] in
            guard let app, let m = app.onboarding?.model, imported.count == 2 else { return }
            ChromiumEngine.installFixture = fixture + "/fixture.crx"
            PasswordManagerCatalog.testExtensionIDs["1password"] = fixtureID
            m.pmChoice = "1password"
            m.pmChosenProfiles = Set(imported)   // the user unticks the default profile
            check(app.store.orderedProfiles.count >= 2, "pwmanager: profiles to choose from (\(app.store.orderedProfiles.count))")
            m.onPasswordManagerInstall?()
            check(m.pmInstalling, "pwmanager: Add 1Password starts the installs")
        }
        step { [self] done in
            // Each review shows on the onboarding window; answer them in order.
            func poll(_ left: Int) {
                guard let m = self.app?.onboarding?.model else { return done() }
                if let r = m.pmReview {
                    reviews += 1
                    if reviews == 1 {
                        self.check(r.profileName == self.app?.store.profile(imported[0])?.name || r.profileName == self.app?.store.profile(imported[1])?.name,
                                   "pwmanager: the review names its destination profile (\(r.profileName))")
                    }
                    r.onAnswer?(answers.isEmpty ? false : answers.removeFirst())
                }
                if m.pmResults != nil || left == 0 { return done() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll(left - 1) }
            }
            poll(120)
        }
        step { [self] done in
            guard let w = app?.onboarding?.window else { return done() }
            captureWindow(w, name: "pwmanager-3-results-chromium", rounded: 24, done)
        }
        run { [self] in
            guard let app, let m = app.onboarding?.model, let results = m.pmResults else { return check(false, "pwmanager: results shown") }
            check(reviews == 2, "pwmanager: one review per chosen profile (\(reviews))")
            check(results.count == 2 && Set(results.map(\.profileID)) == Set(imported), "pwmanager: a result for each chosen profile")
            let yes = results.filter(\.present).map(\.profileID), no = results.filter { !$0.present }.map(\.profileID)
            check(yes.count == 1 && no.count == 1, "pwmanager: one installed, one declined (\(results.map(\.message)))")
            check(results.first { !$0.present }?.message == "Denied — not installed", "pwmanager: the declined profile says so")
            for pid in imported { check(installed(pid, fixtureID) == yes.contains(pid), "pwmanager: the registry matches each profile's answer") }
            guard yes.count == 1, no.count == 1 else { return }
            let others = app.store.orderedProfiles.map(\.id).filter { !imported.contains($0) }
            check(!others.contains { installed($0, fixtureID) }, "pwmanager: an unticked profile gets nothing (\(others.count))")
            check(offered(yes[0]) == false, "pwmanager: Airc stops offering to save passwords where the manager went in")
            check(offered(no[0]) == true && others.allSatisfy { offered($0) == true }, "pwmanager: the other profiles still offer to save")
            check(m.pmSavingTurnedOff == yes && m.pmOutcome == .installed, "pwmanager: the step says which profiles changed")
            check(TestAnchors.frames["onboarding.pm.store." + no[0]] != nil, "pwmanager: the declined profile can open the Web Store")
        }
        step { done in
            server = try? PasswordManagerStoreServer()
            guard let server else { return done() }
            server.start { port in
                ArcExtensionChecklist.testStoreBase = URL(string: "http://chromewebstore.google.com:\(port)")
                done()
            }
        }
        run { [self] in
            guard let m = app?.onboarding?.model, let no = m.pmResults?.first(where: { !$0.present }) else { return }
            server?.expected = "/detail/" + fixtureID
            m.onPasswordManagerOpenStore?(no.profileID)
            let c = app?.controller
            check(c.map { $0.store.profile(ofSpace: $0.currentSpaceID).id == no.profileID } == true,
                  "pwmanager: the Web Store opens in a Space of that profile")
        }
        wait(3)
        run { [self] in
            check(server?.requested == true, "pwmanager: the loopback Web Store stand-in got the extension's page")
            app?.onboarding?.model.onPasswordManagerContinue?()
        }
        wait(0.8)
        run { [self] in
            check(app?.onboarding == nil, "pwmanager: Continue closes the step opened from Settings")
            app?.showSettings(page: .importing)
        }
        wait(1.2)
        run { [self] in
            guard let app, let v = app.settingsWindow?.window.contentView else { return }
            let pid = imported.first { offered($0) == false }
            if let pid, let row = TestAnchors.view("settings.pm.offer." + pid, in: v) { row.scrollToVisible(row.bounds) }
            check(pid.map { TestAnchors.view("settings.pm.offer." + $0, in: v) != nil } == true,
                  "pwmanager: Settings shows each profile's offer to save passwords")
            if let pid, let ep = app.profiles.engineProfile(for: pid) {
                app.engine.setPasswordsOffered(true, for: ep)
                check(offered(pid) == true, "pwmanager: it can be turned back on")
            }
        }
        step { [self] done in
            guard let w = app?.settingsWindow?.window else { return done() }
            captureWindow(w, name: "pwmanager-4-settings-chromium", rounded: 12, done)
        }
        run { [self] in
            server?.stop()
            ChromiumEngine.installFixture = nil
            PasswordManagerCatalog.testExtensionIDs = [:]
            ArcExtensionChecklist.testStoreBase = nil
            cleanUp()
        }
        #else
        run { [self] in check(false, "pwmanager: Chromium build without AircCore"); cleanUp() }
        #endif

    }
}

/// The Web Store stand-in on loopback: answers every request, notes the extension's page.
final class PasswordManagerStoreServer {
    let listener: NWListener
    var requested = false
    var expected = ""
    init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        p.acceptLocalOnly = true
        listener = try NWListener(using: p)
    }
    func start(_ ready: @escaping (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port { ready(port.rawValue) }
        }
        listener.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let e = self?.expected, !e.isEmpty, String(decoding: data ?? Data(), as: UTF8.self).contains(e) { self?.requested = true }
                let body = "<title>Synthetic Web Store</title>Add to Chrome"
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8),
                       completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .main)
    }
    func stop() { listener.cancel() }
}
#endif
