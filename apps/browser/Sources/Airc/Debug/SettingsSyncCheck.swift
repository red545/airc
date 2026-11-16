// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import CryptoKit

/// `--script settingssync-a`, `-b`, `-a2` (docs/sync.md, "Settings"): settings sync between two app instances through a
/// mock CloudKit database in a shared folder (`--sync-mock`), each with its own fake keychain (`--sync-keychain`; a
/// copied key file plays iCloud Keychain). Never the real iCloud or keychain. Synthetic values only.
///
/// - `settingssync-a`: Mac A turns sync on, then changes its theme (dark, no translucency), a shortcut (⌃⌥⌘G for Boost
///   Gallery), adds a Site Search, puts the sidebar on the right, and changes per-Mac settings (backup folder, Developer
///   Mode, memory). What it sent: version 4 batches, only allowlisted keys, none of the per-Mac ones, nothing readable.
/// - `settingssync-b`: Mac B first changes "After an update" itself (after A did: the later change), then turns sync on
///   and merges. A's theme, shortcut (in the live map), Site Search (its default profile) and sidebar side arrive and
///   apply at once; its own per-Mac settings stay; its later choice stays. Settings › Sync shows "Sync settings".
/// - `settingssync-a2`: Mac A again: B's later "After an update" choice won here too; B's per-Mac settings didn't come.
extension SnapshotRunner {
    func settingsSyncScenario() {
        let sync = SyncCenter.shared
        let args = ProcessInfo.processInfo.arguments
        func folder(_ name: String) -> URL? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil }
        }
        guard let mock = folder("--sync-mock"), let keychain = folder("--sync-keychain") else {
            note("FAIL \(script): needs --sync-mock and --sync-keychain")
            return
        }
        let firstKeychain = keychain.deletingLastPathComponent().appendingPathComponent("keychain-a", isDirectory: true)
        let database = try? SyncFolderCloudDatabase(folder: mock)
        let gallery = "file.boostGallery"
        let combo = KeyCombo("g", [.control, .option, .command])
        let searchName = "Example Docs", searchKeyword = "exd", searchTemplate = "https://docs.example.com/search?q=%s"

        func batches() -> [SyncEnvelope] {
            ((try? database?.withState { $0 })?.records(zone: SyncCloudSchema.zone) ?? []).compactMap(SyncCloudSchema.envelope)
        }
        /// Every setting operation in iCloud, opened with the group key from A's keychain.
        func settingOps() -> [SyncOperation] {
            guard let state = try? database?.withState({ $0 }),
                  let group = state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.group).first,
                  let key = try? FolderSyncKeyStore(folder: firstKeychain).key(group: group.group) else { return [] }
            return batches().flatMap { (try? $0.open(group: group.group, key: key)) ?? [] }.filter { $0.record.kind == .setting }
        }
        func waitFor(_ what: String, timeout: Double = 30, _ condition: @escaping () -> Bool) {
            step { [self] done in
                waitUntil(condition, timeout: timeout) { [self] in
                    if !condition() { note("FAIL \(script): timed out waiting for \(what) (status \(sync.status))") }
                    done()
                }
            }
        }
        func shot(_ name: String) {
            step { [self] done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                    if let v = app?.settingsWindow?.window.contentView, let img = render(v), let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent(name + ".png"))
                        note("wrote \(name).png")
                    }
                    done()
                }
            }
        }
        var settings: AppSettings? { app?.settings }
        /// A per-Mac backup folder that exists (the first sync on B backs up into it), inside this run's data folder.
        func backupFolder(_ name: String) -> String {
            let url = AppPaths.dataDirectory.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        let perMac = ["app.backupFolder", "app.developerAutomatic", "app.unloadAfterMinutes"]

        switch script {
        case "settingssync-a":
            run { [self] in
                check(sync.isAvailable && !sync.isEnabled && sync.syncsSettings, "settingssync-a: sync off at first, Sync settings on by default")
                sync.setEnabled(true)
            }
            waitFor("the first upload") { sync.status == .upToDate }
            run { [self] in
                guard let settings, let app else { return }
                var v = settings.values
                v.defaultAppearance = .dark
                v.translucency = .off
                v.backupFolder = backupFolder("Backups A elsewhere")
                v.developerAutomatic = false
                v.unloadAfterMinutes = 5
                _ = v.siteSearch.add(name: searchName, keyword: searchKeyword, template: searchTemplate, to: app.store.defaultProfile.id)
                settings.values = v
                // Through Settings' own paths: the shortcut map, the sidebar side.
                let outcome = ShortcutCenter.shared.update { $0.assign(combo, to: gallery) }
                check(outcome == .done, "settingssync-a: ⌃⌥⌘G assigned to Boost Gallery (\(outcome))")
                app.setSidebarOnRight(true)
                sync.syncNow()
            }
            waitFor("A's settings in iCloud") {
                Set(settingOps().map(\.record.id)).isSuperset(of: ["app.defaultAppearance", "app.shortcuts", "window.sidebarOnRight"])
            }
            run { [self] in
                let ops = settingOps(), keys = Set(ops.map(\.record.id))
                let profile = app?.store.defaultProfile.id ?? "?"
                let expected: Set<String> = ["app.defaultAppearance", "app.translucency", "app.shortcuts", "app.siteSearch@" + profile,
                                             "window.sidebarOnRight"]
                check(keys.isSuperset(of: expected) && keys.allSatisfy(SyncSettings.isSynced),
                      "settingssync-a: theme, shortcut, Site Search and sidebar side went up, only allowlisted keys (\(keys.sorted()))")
                check(perMac.allSatisfy { !keys.contains($0) } && !keys.contains("app.whatsNewStyle"),
                      "settingssync-a: no per-Mac setting went up (backup folder, Developer Mode, memory), nor an unchanged default")
                let v4 = batches().filter { $0.version == SyncSettings.envelopeVersion }
                let raw = (try? database?.withState { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }) ?? ""
                check(!v4.isEmpty && !["docs.example.com", searchKeyword, "Backups A elsewhere", "boostGallery"].contains(where: raw.contains),
                      "settingssync-a: settings went up in \(v4.count) version 4 batch(es); nothing of them is readable in iCloud")
            }
            // A changes "After an update" now; B changes it later, before it syncs (settingssync-b): B's later change wins.
            run { [self] in settings?.values.whatsNewStyle = .card; sync.syncNow() }
            waitFor("A's What's New choice in iCloud") { settingOps().contains { $0.record.id == "app.whatsNewStyle" } }

        case "settingssync-b":
            run { [self] in
                // B's own per-Mac settings, and its later What's New choice, before sync.
                guard let settings else { return }
                var v = settings.values
                v.backupFolder = backupFolder("Backups B elsewhere")
                v.unloadAfterMinutes = 120
                v.whatsNewStyle = .off
                settings.values = v
                let fm = FileManager.default
                try? fm.createDirectory(at: keychain, withIntermediateDirectories: true)
                for file in (try? fm.contentsOfDirectory(at: firstKeychain, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.copyItem(at: file, to: keychain.appendingPathComponent(file.lastPathComponent))
                }
                sync.setEnabled(true)
            }
            waitFor("the first-sync screen or up to date") { sync.firstSync != nil || sync.status == .upToDate }
            run { [self] in
                if sync.firstSync != nil {
                    sync.choose(.merge, profiles: [:]) { [self] error in if let error { note("FAIL settingssync-b: Merge failed: \(error)") } }
                }
            }
            waitFor("up to date after Merge") { sync.status == .upToDate }
            run { sync.syncNow() }
            waitFor("A's theme here", timeout: 20) { [self] in settings?.values.defaultAppearance == .dark }
            run { [self] in
                guard let settings, let app else { return }
                let v = settings.values
                check(v.defaultAppearance == .dark && v.translucency == .off,
                      "settingssync-b: A's theme arrived (appearance \(v.defaultAppearance), translucency \(v.translucency))")
                check(ShortcutCenter.shared.map.key(gallery) == combo && v.shortcuts[gallery] != nil,
                      "settingssync-b: A's shortcut arrived and is live (Boost Gallery: \(ShortcutCenter.shared.map.key(gallery)?.description ?? "none"))")
                let searches = v.siteSearch.searches(for: app.store.defaultProfile.id)
                check(searches.contains { $0.keyword == searchKeyword && $0.template == searchTemplate && $0.name == searchName },
                      "settingssync-b: A's Site Search arrived on this Mac's default profile (\(searches.count) sites)")
                check(app.store.windowState.sidebarOnRight && app.controllers.allSatisfy(\.sidebarOnRight),
                      "settingssync-b: the sidebar moved to the right in every window")
                check(v.backupFolder?.hasSuffix("Backups B elsewhere") == true && v.developerAutomatic && v.unloadAfterMinutes == 120,
                      "settingssync-b: per-Mac settings stayed this Mac's (backup folder, Developer Mode, memory)")
                check(v.whatsNewStyle == .off, "settingssync-b: its own later What's New choice won over A's earlier one (\(v.whatsNewStyle))")
                app.showSettings(page: .sync)
            }
            shot("settingssync-settings")
            run { [self] in
                check(sync.isEnabled && sync.syncsSettings, "settingssync-b: Settings › Sync shows Sync settings, on")
                sync.syncNow()
            }
            waitFor("B's What's New choice in iCloud") {
                let me = sync.engine.map { e in MainActor.assumeIsolated { e.deviceID } }
                return settingOps().contains { $0.record.id == "app.whatsNewStyle" && $0.stamp.device == me }
            }

        case "settingssync-a2":
            run { sync.syncNow() }
            waitFor("B's later What's New choice here", timeout: 20) { [self] in settings?.values.whatsNewStyle == .off }
            run { [self] in
                guard let settings else { return }
                let v = settings.values
                check(v.whatsNewStyle == .off, "settingssync-a2: B's later What's New choice won here too (\(v.whatsNewStyle))")
                check(v.backupFolder?.hasSuffix("Backups A elsewhere") == true && v.unloadAfterMinutes == 5 && !v.developerAutomatic,
                      "settingssync-a2: B's per-Mac settings didn't come (backup folder, memory, Developer Mode stay A's)")
                check(v.defaultAppearance == .dark && ShortcutCenter.shared.map.key(gallery) == combo,
                      "settingssync-a2: its own theme and shortcut stayed")
                check(sync.status == .upToDate, "settingssync-a2: up to date (\(sync.status))")
            }

        default:
            note("FAIL unknown script \(script)")
        }
    }
}
#endif
