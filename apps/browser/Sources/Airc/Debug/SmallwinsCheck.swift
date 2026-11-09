// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
import AircDesign
import SwiftUI
import QuartzCore
#if canImport(AircCore)
import AircCore
#endif

extension SnapshotRunner {
    func smallwinsScenario() {
        let folder = dir.appendingPathComponent("backups")
        var older = Data(), oldTab = "", laterTab = "", second: WindowController?
        var oldState = StoreState(), currentState = StoreState()
        step { [self] done in
          Task { @MainActor in
            defer { done() }
            do {
                c.closeCommandBar()
                app?.settings.values.backupFolder = folder.path
                let sid = c.currentSpaceID
                try c.store.updateSpace(sid) { $0.name = "Earlier Space" }
                oldTab = try c.store.openTab(url: "about:blank", inSpace: sid, activate: false, title: "Earlier tab").id
                let archived = try c.store.openTab(url: "https://example.com/archive", inSpace: sid, activate: false, title: "Earlier archive")
                _ = try c.store.closeTab(archived.id)
                older = try c.store.exportJSON()
                _ = try c.store.writeBackup(to: folder, purpose: .manual)
                oldState = try SpacesStore.readBackup(older).state
                try c.store.updateSpace(sid) { $0.name = "Later Space" }
                laterTab = try c.store.openTab(url: "about:blank", inSpace: sid, activate: false, title: "Later tab").id
                _ = try c.store.writeBackup(to: folder, purpose: .manual)
                currentState = try SpacesStore.readBackup(c.store.exportJSON()).state
                second = app?.openNewWindow(from: c, spaceID: sid, commandBar: false,
                    frame: NSRect(x: -6000, y: -3000, width: 1100, height: 750))
                let catalog = try SpacesStore.listBackups(in: folder)
                check(catalog.count == 2 && catalog.allSatisfy { $0.archived == 1 && $0.size > 0 && $0.date != nil },
                      "backup catalog reads dates, sizes and counts")
                let recovery = try await app!.restoreBackup(older)
                check(try SpacesStore.readBackup(Data(contentsOf: recovery)).state == currentState,
                      "fresh pre-restore backup contains the state being replaced")
                check(c.store.state.spaces == oldState.spaces && Set(c.store.state.tabs.keys) == Set(oldState.tabs.keys), "older backup restores Spaces and tabs")
                let restored = c.store.state
                do {
                    _ = try await app!.restoreBackup(Data("corrupt".utf8))
                    check(false, "corrupt backup must be refused")
                } catch { check(c.store.state == restored, "corrupt backup refused with state untouched") }
                check(BackupRestorePicker.confirmation(Date()).contains("A backup of the current state is saved first."),
                      "confirmation explains replacement and recovery")
            } catch { check(false, "restore setup: \(error)") }
          }
        }
        wait(0.6)
        run { [self] in
            for window in [c, second].compactMap({ $0 }) {
                let rows = window.pageView(for: window.currentSpaceID)?.rows ?? [:]
                check(rows[oldTab] != nil && rows[laterTab] == nil, "every window sidebar shows older tab and removes later tab")
            }
        }
        capture("smallwins-restored")
        run { second?.window.close(); second = nil }
        let restoreClock = FrameClock()
        var restoreStart: CFTimeInterval = 0
        run { [self] in restoreClock.start(on: c.root) }
        wait(0.5)
        step { [self] done in
            Task { @MainActor in
                defer { done() }
                do {
                    let bytes = older
                    let large = try await Task.detached {
                        var backup = try SpacesStore.readBackup(bytes)
                        let sid = backup.state.spaces.keys.sorted().first!
                        let pid = backup.state.spaces[sid]!.profileID
                        for i in 0..<5000 {
                            let tab = LiveTab(profileID: pid, spaceID: sid, url: "about:blank", title: "Synthetic \(i)", order: Double(i), createdAt: backup.exportedAt)
                            backup.state.tabs[tab.id] = tab
                        }
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                        return try encoder.encode(backup)
                    }.value
                    restoreStart = CACurrentMediaTime()
                    _ = try await app!.restoreBackup(large)
                    check(c.store.state.tabs.count >= 5000, "large backup restores 5000 tabs")
                    if let page = c.pageView(for: c.currentSpaceID) {
                        check(page.rows.count < 100, "large backup materializes only viewport rows")
                        page.scrollView.contentView.scroll(to: NSPoint(x: 0, y: page.list.bounds.maxY - page.scrollView.contentSize.height))
                        page.scrollView.reflectScrolledClipView(page.scrollView.contentView)
                        check(page.rows.values.contains { $0.frame.minY > 100_000 }, "large backup bottom rows materialize on scroll")
                        page.scrollView.contentView.scroll(to: .zero)
                        page.scrollView.reflectScrolledClipView(page.scrollView.contentView)
                    }
                    note("large restore main apply: \(c.store.lastRestoreApplyDuration * 1000) ms")
                    check(c.store.lastRestoreApplyDuration < 0.016, "large restore store apply under 16 ms")
                } catch { check(false, "large restore: \(error)") }
            }
        }
        wait(0.5)
        run { [self] in
            let gaps = restoreClock.deltas(from: restoreStart, to: CACurrentMediaTime())
            note("large restore frames: \(FrameStats(gaps))")
            if restoreClock.isTicking {
                check((gaps.max() ?? .infinity) < 100, "large restore has no 100 ms frozen frame")
            } else { note("SKIP large restore frame stall: display link is not ticking") }
            restoreClock.stop()
        }
        step { [self] done in
            Task { @MainActor in
                do { _ = try await app!.restoreBackup(older) }
                catch { check(false, "restore fixture cleanup: \(error)") }
                done()
            }
        }
        #if canImport(AircCore)
        if app?.engine.name.hasPrefix("Chromium") == true {
            var extensionID = "", otherID = ""
            step { [self] done in
                guard Self.engineTestGateOpens,
                      let profile = c.profiles.engineProfile(for: c.currentProfileID) as? ChromiumProfile else {
                    check(false, "unpacked extension needs the scratch-profile test gate")
                    return done()
                }
                let fixture = dir.appendingPathComponent("test-extension")
                do {
                    try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                    let manifest = #"{"manifest_version":3,"name":"Airc test","version":"1","action":{"default_title":"Airc test action"}}"#
                    try manifest.write(to: fixture.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
                    profile.core.loadUnpackedExtension(forTesting: fixture.path) { id, error in
                        DispatchQueue.main.async {
                            extensionID = id ?? ""
                            if let error { self.note("fixture load: \(error)") }
                            done()
                        }
                    }
                } catch { check(false, "fixture creation: \(error)"); done() }
            }
            run { [self] in
                extensionID = c.extensionActions().first?.id ?? ""
                check(!extensionID.isEmpty, "unpacked test extension is installed in source profile")
                do { otherID = try c.store.createProfile(name: "Other profile", emoji: "").id }
                catch { check(false, "create destination profile: \(error)") }
            }
            step { [self] done in
                c.installExtensionInAllProfiles(extensionID) { results in
                    let result = results.first { $0.profileID == otherID }
                    self.check(result?.tabID == nil && result?.message.contains("No Space") == true,
                               "profile without a Space reports why it cannot open the Web Store")
                    self.check(self.c.store.spaces(usingProfile: otherID).isEmpty,
                               "install action never creates a Space silently")
                    done()
                }
            }
            run { [self] in
                do {
                    _ = try c.store.createSpace(name: "First destination", profileID: otherID)
                    let second = try c.store.createSpace(name: "Second destination", profileID: otherID)
                    // The Web Store redirect adds a localized slug and query; it is not in the first Space.
                    _ = try c.store.openTab(url: "https://chromewebstore.google.com/detail/reader/\(extensionID)?hl=de#reviews",
                                           inSpace: second.id, activate: false, title: "Existing Web Store")
                } catch { check(false, "destination setup: \(error)") }
            }
            step { [self] done in
                let before = c.store.state.tabs.count
                c.installExtensionInAllProfiles(extensionID) { results in
                    self.check(self.c.store.state.tabs.count == before && results.first(where: { $0.profileID == otherID })?.message.contains("already open") == true,
                               "repeat action reuses a redirected Web Store URL in another Space")
                    done()
                }
            }
            step { [self] done in
                if let space = c.store.orderedSpaces.first(where: { $0.profileID == otherID }) { c.switchToSpace(space.id, animated: false) }
                c.installExtensionInAllProfiles(extensionID) { results in
                    self.check(results.contains { $0.message.contains("Already installed") && $0.tabID == nil },
                               "installed source profile is skipped from other profile")
                    done()
                }
            }
        }
        #endif
    }

    /// Render the actual picker without bringing the Settings window to the front.
    func mkSmallwinsShots() {
        var window: NSWindow?
        run { [self] in
            guard let app else { return }
            let folder = dir.appendingPathComponent("demo-backups")
            app.settings.values.backupFolder = folder.path
            _ = try? c.store.writeBackup(to: folder, purpose: .manual)
            let view = BackupRestorePicker(model: SettingsModel(app: app)).aircTheme(DesignTheme.default.resolved(systemIsDark: false))
            let host = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: host)
            w.setFrameOrigin(NSPoint(x: -6000, y: -3000))
            w.orderFront(nil)
            window = w
        }
        wait(1)
        step { [self] done in
            defer { done() }
            guard let w = window, let image = mkContentImage(w), let view = w.contentView else {
                return note("marketing: MISSING backup-restore")
            }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("backup-restore", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: image, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w))
            ])
        }
        run { window?.orderOut(nil); window = nil }
        step { [self] done in
            _ = try? c.store.createProfile(name: "Reading", emoji: "")
            let id = "ddkjiahejlhfcafbddmgiahcphecmpfh" // uBlock Origin Lite's Web Store ID
            c.installExtensionInAllProfiles(id) { results in
                let view = ExtensionProfileResults(name: "uBlock Origin Lite", results: results, done: {})
                    .aircTheme(DesignTheme.default.resolved(systemIsDark: false))
                let w = NSWindow(contentViewController: NSHostingController(rootView: view))
                w.setFrameOrigin(NSPoint(x: -6000, y: -3000))
                w.orderFront(nil)
                window = w
                done()
            }
        }
        wait(0.6)
        step { [self] done in
            defer { done() }
            guard let w = window, let image = mkContentImage(w), let view = w.contentView else {
                return note("marketing: MISSING extension-profiles")
            }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("extension-profiles", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: image, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w))
            ])
        }
        run { window?.orderOut(nil); window = nil }
    }
}
#endif
