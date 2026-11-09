// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircImport
import AircKit
import AppKit
import Network

/// Every file is generated under the test's directory. No real Arc discovery or credential import.
enum ArcImport2Fixture {
    static let extensionID = String(repeating: "a", count: 32)
    static func write(_ root: URL) throws {
        let fm = FileManager.default
        func json(_ path: String, _ value: Any) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        let spaces: [[String: Any]] = [
            ["id": "im-personal", "title": "Personal", "profile": ["default": [:]], "containerIDs": []],
            ["id": "im-work", "title": "Work", "profile": ["custom": ["_0": ["directoryBasename": "Profile 1"]]], "containerIDs": []]
        ]
        try json("StorableSidebar.json", ["version": 1, "sidebar": ["containers": [["global": [:]], ["spaces": spaces, "items": []]]]])
        for p in ["Default", "Profile 1"] {
            try json("User Data/\(p)/Preferences", ["extensions": ["settings": [extensionID: ["manifest": ["name": "__MSG_title__", "version": "1"], "path": extensionID + "/1_0", "location": 1, "state": p == "Default" ? 1 : 0]]]])
            let extensionRoot = "User Data/\(p)/Extensions/\(extensionID)/1_0"
            try json(extensionRoot + "/manifest.json", ["name": "__MSG_title__", "default_locale": "en"])
            try json(extensionRoot + "/_locales/en/messages.json", ["title": ["message": "Localized Reader"]])
            let t = Int64((Date().timeIntervalSince1970 + 11_644_473_600 - 3600) * 1_000_000)
            _ = try BrowserFixtures.sqlite(root.appendingPathComponent("User Data/\(p)/History"), """
            CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
            INSERT INTO urls VALUES('https://example.com/\(p == "Default" ? "personal" : "work")','Synthetic Arc constellation',3,1,\(t),0);
            """)
        }
    }
}

extension SnapshotRunner {
    func arcImport2Scenario(marketing: Bool = false) {
        let root = dir.appendingPathComponent("synthetic-arc")
        var server: ArcImport2Server?
        run { [self] in
            do { try ArcImport2Fixture.write(root) } catch { check(false, "arcimport2: synthetic tree written") }
            OnboardingController.testArcDirectory = root
            app?.startOnboarding(mode: .rerun, atImport: true)
        }
        step { [self] done in
            let started = Date()
            waitUntil({ self.app?.onboarding?.model.hasArc == true }, timeout: 30) {
                self.note("arcimport2: discovery finished after \(Date().timeIntervalSince(started)) s; stage \(self.app?.onboarding?.model.arcReadProgress ?? "none")")
                done()
            }
        }
        run { [self] in
            check(app?.onboarding?.model.hasArc == true, "arcimport2: onboarding reads the synthetic Arc tree")
            app?.onboarding?.model.includeLogins = false
            app?.onboarding?.model.onImportEverything?()
        }
        step { [self] done in
            waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30, then: done)
        }
        run { [self] in
            guard let app, let m = app.onboarding?.model, let result = m.result else { return check(false, "arcimport2: imported") }
            check(m.historyImported == 2, "arcimport2: summary counts two history entries")
            for key in ["arc-profile:Default", "arc-profile:Profile 1"] {
                guard let pid = result.profileIDs[key] else { check(false, "arcimport2: mapped profile"); continue }
                let hits = app.history.search("constellation", profileID: pid)
                check(hits.count == 1 && hits.first?.entry.url.hasSuffix(key.hasSuffix("Default") ? "personal" : "work") == true,
                      "arcimport2: command bar history search is isolated per imported profile")
            }
            check(TestAnchors.frames["arcimport2.checklist"] != nil, "arcimport2: checklist visible after import")
            check(ArcExtensionChecklist.shared.rows.count == 2, "arcimport2: extensions stay per profile")
            check(ArcExtensionChecklist.shared.rows.allSatisfy { $0.extensionInfo.name == "Localized Reader" },
                  "arcimport2: checklist resolves manifest locale names")
            check(ArcExtensionChecklist().rows.count == 2, "arcimport2: checklist survives reload")
            if let pid = result.profileIDs["arc-profile:Default"] {
                ArcExtensionChecklist.testInstalled[pid] = [ArcImport2Fixture.extensionID]
            }
        }
        wait(2.2)
        run { [self] in
            guard let app else { return }
            let rows = ArcExtensionChecklist.shared.rows
            check(rows.filter { ArcExtensionChecklist.installed($0, app: app) }.count == 1,
                  "arcimport2: installed status belongs only to the matching destination profile")
            check(rows.contains { TestAnchors.frames["arcimport2.installed." + $0.id] != nil }, "arcimport2: installed extension is marked in the checklist")
        }
        step { [self] done in
            guard let w = app?.onboarding?.window else { return done() }
            if marketing { captureWindow(w, name: "arc-import-checklist", rounded: 24, done) }
            else { captureWindow(w, name: "arcimport2-checklist", rounded: 24, done) }
        }
        if marketing {
            run { [self] in app?.onboarding?.requestClose(); OnboardingController.testArcDirectory = nil; try? FileManager.default.removeItem(at: root) }
            // P22: the login results, with what didn't come over and why, and Try Again (ImportAcceptanceCheck.swift).
            arcImportLoginsShot()
            return
        }
        // Import a second time through onboarding: unchanged visit counts, profiles and checklist rows.
        run { [self] in app?.onboarding?.requestClose(); app?.startOnboarding(mode: .rerun, atImport: true) }
        step { [self] done in
            waitUntil({ self.app?.onboarding?.model.hasArc == true }, timeout: 30) {
                self.check(self.app?.onboarding?.model.hasArc == true, "arcimport2: reimport discovery completes")
                done()
            }
        }
        run { [self] in app?.onboarding?.model.includeLogins = false; app?.onboarding?.model.onImportEverything?() }
        step { [self] done in
            waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30) {
                self.check(self.app?.onboarding?.model.result != nil, "arcimport2: reimport completes")
                done()
            }
        }
        run { [self] in
            guard let app, let result = app.onboarding?.model.result else { return }
            check(result.profilesCreated.isEmpty && result.spacesCreated == 0, "arcimport2: reimport creates no profiles or Spaces")
            check(result.profileIDs.values.allSatisfy { app.history.entries(ofProfile: $0).count == 1 && app.history.entries(ofProfile: $0).first?.visitCount == 3 }, "arcimport2: reimport dedupes history and visit counts")
        }
        step { done in
            server = try? ArcImport2Server()
            guard let server else { return done() }
            server.start { port in
                #if canImport(AircCore)
                ArcExtensionChecklist.testStoreBase = URL(string: "http://chromewebstore.google.com:\(port)")
                #else
                ArcExtensionChecklist.testStoreBase = URL(string: "http://127.0.0.1:\(port)")
                #endif
                done()
            }
        }
        run { [self] in
            guard let app, let row = ArcExtensionChecklist.shared.rows.first(where: { !($0.extensionInfo.enabled) }) else { return }
            check(row.extensionInfo.storeURL.absoluteString == "https://chromewebstore.google.com/detail/" + ArcImport2Fixture.extensionID, "arcimport2: production Web Store URL")
        }
        step { [self] done in
            guard let o = app?.onboarding, let row = ArcExtensionChecklist.shared.rows.first(where: { !$0.extensionInfo.enabled }),
                  let host = MainActor.assumeIsolated({ o.window.contentContainer.subviews.first }) else { return done() }
            clickAnchor("arcimport2.store." + row.id, in: host, done)
        }
        wait(0.5)
        run { [self] in
            guard let row = ArcExtensionChecklist.shared.rows.first(where: { !$0.extensionInfo.enabled }) else { return }
            check(c.store.profile(ofSpace: c.currentSpaceID).id == row.profileID, "arcimport2: Web Store action selects the extension’s profile Space")
            check(c.store.todayTabs(ofSpace: c.currentSpaceID).contains { $0.url == ArcExtensionChecklist.testStoreBase!.appendingPathComponent("detail/" + row.extensionInfo.id).absoluteString }, "arcimport2: Web Store action opens the expected URL")
        }
        wait(3)
        run { [self] in
            check(server?.requested == true, "arcimport2: loopback Web Store stand-in received the page request")
            app?.onboarding?.requestClose()
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("constellation")
            server?.stop()
            ArcExtensionChecklist.testStoreBase = nil
            ArcExtensionChecklist.testInstalled = [:]
            OnboardingController.testArcDirectory = nil
            try? FileManager.default.removeItem(at: root)
        }
        wait(0.8)
        run { [self] in
            check(c.commandBar?.resultTitles.contains(where: { $0.hasPrefix("Synthetic Arc constellation (") }) == true, "arcimport2: ⌘T renders the imported synthetic page")
            c.closeCommandBar()
            TestAnchors.frames["arcimport2.checklist"] = nil
            app?.showSettings(page: .importing)
        }
        wait(0.8)
        run { [self] in check(TestAnchors.frames["arcimport2.checklist"] != nil, "arcimport2: checklist available in Settings Import") }
    }
}

private final class ArcImport2Server {
    let listener: NWListener
    var requested = false
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
                if String(decoding: data ?? Data(), as: UTF8.self).contains("/detail/" + ArcImport2Fixture.extensionID) { self?.requested = true }
                let body = "<title>Synthetic Web Store</title>Reinstall your extension"
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: .main)
    }
    func stop() { listener.cancel() }
}
#endif
