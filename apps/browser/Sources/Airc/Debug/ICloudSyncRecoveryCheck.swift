// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import CryptoKit

/// `--script icloudsync-recovery-a`, `-b`, `-c`, `-a2` (docs/sync.md, "Recovery key" and "Starting over"; P14b4), both
/// engines: three app instances share a mock CloudKit database in a folder (`--sync-mock`), each with its own fake
/// keychain (`--sync-keychain`). No key file is ever copied: these Macs have no iCloud Keychain. Never the real iCloud,
/// never the real keychain; the keys are the test keychains' own, synthetic.
///
/// - `-a`: Mac A turns sync on and uploads Work. Settings › Sync shows "Recovery key"; Show… gives 14 groups of 4 that
///   are A's key (icloudsync-recovery-key.png). A writes it, and its group, to the shared test folder (the person
///   copying it). Then sync goes off on A and A pins a tab that never reaches iCloud.
/// - `-b`: Mac B (no iCloud Keychain) waits for the key, with Use Recovery Key… and Start Over… in Settings
///   (icloudsync-recovery-waiting.png, -enter.png). A typo and another sync's key are refused, and nothing changes.
///   A's key makes the first-sync screen open; Merge, after a backup, brings A's Work in, and B's own Space goes up.
/// - `-c`: Mac C has no key and starts over (the confirmation: icloudsync-recovery-startover.png). There's a backup,
///   then a new group in iCloud with C's sidebar. A's batches are still there (nothing deleted). C writes its
///   recovery key.
/// - `-a2`: Mac A turns sync on again. It notices the new group and keeps its sidebar, including the tab that never
///   synced. It waits for the key; C's recovery key opens the first-sync screen saying sync was started over
///   (icloudsync-recovery-rejoin.png), with Merge preselected. Merge, after a backup, gives A both sidebars with
///   nothing twice. A's old key stays in its keychain.
extension SnapshotRunner {
    func iCloudSyncRecoveryScenario() {
        let sync = SyncCenter.shared
        let args = ProcessInfo.processInfo.arguments
        let tag = app?.engine.name.hasPrefix("Chromium") == true ? "chromium" : "webkit"
        func folder(_ name: String) -> URL? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil }
        }
        guard let mock = folder("--sync-mock"), let keychain = folder("--sync-keychain") else {
            note("FAIL \(script): needs --sync-mock and --sync-keychain")
            return
        }
        let shared = mock.deletingLastPathComponent()
        let keyFileA = shared.appendingPathComponent("recovery-key-a.txt"), groupFileA = shared.appendingPathComponent("recovery-group-a.txt")
        let keyFileC = shared.appendingPathComponent("recovery-key-c.txt")
        let database = try? SyncFolderCloudDatabase(folder: mock)
        let fm = FileManager.default
        func say(_ ok: Bool, _ what: String) { check(ok, "\(script) (\(tag)): " + what) }
        func records() -> [SyncCloudRecord] { ((try? database?.withState { $0 })?.records(zone: SyncCloudSchema.zone)) ?? [] }
        func zoneGroup() -> SyncGroupRecord? { records().compactMap(SyncCloudSchema.group).first }
        func keyFiles() -> [String] { ((try? fm.contentsOfDirectory(atPath: keychain.path)) ?? []).filter { $0.hasSuffix(".key") }.sorted() }
        /// Every operation of the zone's group, opened with `key`.
        func opened(_ key: SymmetricKey?) -> String {
            guard let key, let group = zoneGroup()?.group else { return "" }
            let ops = records().compactMap(SyncCloudSchema.envelope).filter { $0.group == group }.flatMap { (try? $0.open(group: group, key: key)) ?? [] }
            return String(decoding: (try? JSONEncoder().encode(ops)) ?? Data(), as: UTF8.self)
        }
        func waitFor(_ what: String, timeout: Double = 30, _ condition: @escaping () -> Bool) {
            step { [self] done in
                waitUntil(condition, timeout: timeout) { [self] in
                    if !condition() { note("FAIL \(script) (\(tag)): timed out waiting for \(what) (status \(sync.status))") }
                    done()
                }
            }
        }
        func shot(_ name: String, sheet: Bool = false) {
            step { [self] done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                    let window = sheet ? app?.settingsWindow?.window.attachedSheet : app?.settingsWindow?.window
                    if let v = window?.contentView, let img = render(v), let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent(name + ".png"))
                        note("wrote \(name).png")
                    } else {
                        note("FAIL \(script) (\(tag)): no \(sheet ? "sheet" : "Settings window") to render for \(name)")
                    }
                    done()
                }
            }
        }
        func spaces(_ name: String) -> Int { c.store.orderedSpaces.filter { $0.name == name }.count }
        func has(_ url: String) -> Bool { c.store.state.items.values.contains { $0.savedURL == url } }
        func backups() -> Int { (try? fm.contentsOfDirectory(atPath: app!.settings.backupDirectory.path))?.count ?? 0 }
        func seed(_ space: String, _ url: String) {
            do {
                let s = try c.store.createSpace(name: space)
                try pin(url, title: space + " home", icon: nil, space: s.id)
                c.switchToSpace(s.id, animated: false)
            } catch { note("FAIL \(script) (\(tag)): seeding: \(error)") }
        }

        switch script {
        case "icloudsync-recovery-a":
            run { [self] in
                seed("Work", "https://example.com/recovery-a")
                app?.showSettings(page: .sync)
                sync.setEnabled(true)
            }
            waitFor("the first upload") { sync.status == .upToDate }
            var shown: String?
            run {
                let key = zoneGroup().flatMap { g in (try? FolderSyncKeyStore(folder: keychain).key(group: g.group)) ?? nil }
                say(sync.hasRecoveryKey && key != nil && opened(key).contains("recovery-a"),
                    "Mac A made the group and sent Work; Settings › Sync offers its recovery key")
                sync.revealRecoveryKey { shown = $0; if let k = $0 { sync.recoverySheet = .show(k) } }
            }
            waitFor("the recovery key sheet") { [self] in shown != nil && app?.settingsWindow?.window.attachedSheet != nil }
            run {
                let key = zoneGroup().flatMap { g in (try? FolderSyncKeyStore(folder: keychain).key(group: g.group)) ?? nil }
                let groups = shown?.split(separator: "-") ?? []
                say(groups.count == 14 && groups.allSatisfy { $0.count == 4 } && key.map(SyncRecoveryKey.format) == shown,
                    "Show… gives 14 groups of 4, and they are this sync's key")
                try? shown?.write(to: keyFileA, atomically: true, encoding: .utf8)
                try? zoneGroup()?.group.uuidString.write(to: groupFileA, atomically: true, encoding: .utf8)
            }
            shot("icloudsync-recovery-key", sheet: true)
            run { [self] in
                sync.recoverySheet = nil
                sync.setEnabled(false)
                // Pinned while sync is off: this never reaches iCloud before the start-over.
                if let work = c.store.orderedSpaces.first(where: { $0.name == "Work" }) {
                    try? pin("https://example.com/a-unsynced", title: "Unsynced", icon: nil, space: work.id)
                }
            }
            wait(0.5)

        case "icloudsync-recovery-b":
            var start = 0
            run { [self] in
                seed("Laptop", "https://example.org/recovery-b")
                start = backups()
                app?.showSettings(page: .sync)
                sync.setEnabled(true)
            }
            waitFor("waiting for the key") { sync.status == .waitingForKeychain }
            run { sync.syncNow() }
            wait(1.5)
            run { [self] in
                say(sync.status == .waitingForKeychain && keyFiles().isEmpty && spaces("Work") == 0 && !sync.hasRecoveryKey,
                    "no iCloud Keychain here: it keeps waiting, no key comes, nothing changes")
            }
            shot("icloudsync-recovery-waiting")
            run { sync.recoverySheet = .enter }
            wait(0.8)
            shot("icloudsync-recovery-enter", sheet: true)
            var answers: [Error?] = [], answered = 0
            run {
                sync.useRecoveryKey("ABCD-EFGH-1234") { answers.append($0); answered += 1 }
                sync.useRecoveryKey(SyncRecoveryKey.format(SymmetricKey(size: .bits256))) { answers.append($0); answered += 1 }
            }
            waitFor("the two refusals") { answered == 2 }
            run { [self] in
                say(answers.count == 2 && answers[0] as? SyncRecoveryFailure == .malformed && answers[1] as? SyncRecoveryFailure == .otherGroup,
                    "a typo is a typo, another sync's key is refused (\(answers.map { $0.map { String(describing: $0) } ?? "nil" }))")
                say(sync.status == .waitingForKeychain && keyFiles().isEmpty && spaces("Work") == 0,
                    "and nothing changed: still waiting, no key kept")
                sync.recoverySheet = nil
                let text = (try? String(contentsOf: keyFileA, encoding: .utf8)) ?? ""
                // Typed the way a person might: small letters, spaces.
                sync.useRecoveryKey(text.lowercased().replacingOccurrences(of: "-", with: " ")) { answers.append($0); answered += 1 }
            }
            waitFor("the first-sync screen") { answered == 3 && sync.firstSync != nil }
            run { [self] in
                say(answers.count == 3 && answers[2] == nil && keyFiles().count == 1 && sync.firstSync?.restartedElsewhere == false
                    && sync.firstSync?.iCloud.spaces.contains("Work") == true,
                    "A's recovery key fits: it's kept in this Mac's keychain, and the usual first-sync screen opens")
                sync.choose(.merge, profiles: [:])
            }
            waitFor("the first sync") { sync.status == .upToDate }
            run { [self] in
                let key = zoneGroup().flatMap { g in (try? FolderSyncKeyStore(folder: keychain).key(group: g.group)) ?? nil }
                say(backups() == start + 1 && has("https://example.com/recovery-a") && spaces("Work") == 1,
                    "Merge, after a backup, brought A's Work in")
                say(opened(key).contains("recovery-b") && sync.hasRecoveryKey, "B's own Space went up; B can show the key too")
            }

        case "icloudsync-recovery-c":
            var start = 0, oldGroup: UUID?, oldBatches = 0
            run { [self] in
                seed("Studio C", "https://example.net/recovery-c")
                start = backups()
                oldGroup = zoneGroup()?.group
                oldBatches = records().compactMap(SyncCloudSchema.envelope).filter { $0.group == oldGroup }.count
                app?.showSettings(page: .sync)
                sync.setEnabled(true)
            }
            waitFor("waiting for the key") { sync.status == .waitingForKeychain }
            run { sync.recoverySheet = .startOver }
            wait(0.8)
            shot("icloudsync-recovery-startover", sheet: true)
            var answer: Error?, answered = false
            run {
                sync.recoverySheet = nil
                sync.startOver { answer = $0; answered = true }
            }
            waitFor("the start-over") { answered && sync.status == .upToDate }
            run { [self] in
                let group = zoneGroup()?.group
                let key = group.flatMap { g in (try? FolderSyncKeyStore(folder: keychain).key(group: g)) ?? nil }
                say(answer == nil && backups() == start + 1 && (sync.lastBackup.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").contains("recovery-c"),
                    "start over backed up this Mac's sidebar first (\(answer.map { String(describing: $0) } ?? "no error"))")
                say(group != nil && group != oldGroup && keyFiles().count == 1 && opened(key).contains("recovery-c"),
                    "a new sync in iCloud, with this Mac's sidebar and a key of its own")
                let left = records().compactMap(SyncCloudSchema.envelope).filter { $0.group == oldGroup }.count
                say(oldBatches > 0 && left == oldBatches, "nothing of the old sync was deleted (\(left) of \(oldBatches) batches)")
                sync.revealRecoveryKey { try? $0?.write(to: keyFileC, atomically: true, encoding: .utf8) }
            }
            wait(0.3)

        case "icloudsync-recovery-a2":
            var start = 0
            let oldGroup = (try? String(contentsOf: groupFileA, encoding: .utf8)).flatMap(UUID.init(uuidString:))
            run { [self] in
                start = backups()
                app?.showSettings(page: .sync)
                sync.setEnabled(true)
            }
            waitFor("waiting for the new sync's key") { sync.status == .waitingForKeychain }
            run { [self] in
                say(!sync.hasRecoveryKey && sync.isEnabled && has("https://example.com/a-unsynced") && has("https://example.com/recovery-a")
                    && !has("https://example.net/recovery-c"),
                    "A noticed the new sync: sync stays on and its sidebar stays as it was, the unsynced tab too; it waits for the new key")
                let text = (try? String(contentsOf: keyFileC, encoding: .utf8)) ?? ""
                sync.useRecoveryKey(text)
            }
            waitFor("the first-sync screen") { sync.firstSync != nil }
            wait(0.6)
            run { [self] in
                say(sync.firstSync?.restartedElsewhere == true && app?.settingsWindow?.window.attachedSheet != nil,
                    "the first-sync screen says sync was started over on another Mac")
            }
            shot("icloudsync-recovery-rejoin", sheet: true)
            run { sync.choose(.merge, profiles: [:]) }
            waitFor("the first sync") { sync.status == .upToDate }
            run { [self] in
                let key = zoneGroup().flatMap { g in (try? FolderSyncKeyStore(folder: keychain).key(group: g.group)) ?? nil }
                say(backups() == start + 1 && has("https://example.net/recovery-c") && has("https://example.com/a-unsynced")
                    && has("https://example.com/recovery-a"),
                    "Merge, after a backup: C's sidebar and everything A had, the unsynced tab included")
                say(spaces("Work") == 1 && spaces("Studio C") == 1, "nothing twice")
                say(opened(key).contains("a-unsynced"), "A's unsynced tab went up to the new sync")
                say(oldGroup.map { g in ((try? FolderSyncKeyStore(folder: keychain).key(group: g)) ?? nil) != nil } == true,
                    "A's old key stays in its keychain")
            }

        default:
            note("FAIL unknown recovery script \(script)")
        }
    }
}
#endif
