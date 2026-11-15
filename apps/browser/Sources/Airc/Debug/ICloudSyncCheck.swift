// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import CryptoKit

/// `--script icloudsync` and its follow-ups (docs/sync.md): iCloud sync between app instances through a mock CloudKit
/// database in a shared folder (`--sync-mock`), each instance with its own fake keychain (`--sync-keychain`; a
/// copied key file plays iCloud Keychain). Never the real iCloud, never the real keychain.
///
/// - `icloudsync`: the first Mac. Settings → Sync shows the switch (off) and what syncs; on, it uploads; nothing
///   of a Today tab, a private window or Little Arc is in what it sent. A pinned note (title, text, a picture) goes up
///   sealed; a note in Today doesn't (P14b1).
/// - `icloudsync-second`: another Mac. Waiting for iCloud Keychain, then the first-sync screen; Merge (after a
///   backup) brings the first Mac's Spaces in, and the note with its title, text and picture; its own edits (the note's
///   too) go up.
/// - `icloudsync-replace`: a third Mac chooses Replace: its own Space goes (backed up, Today tabs archived), nothing
///   of it is sent; but a Space holding its pinned note stays, and the note goes up.
/// - `icloudsync-return`: the first Mac again gets the second's edits at launch (the note's text too), and a push
///   brings a change in while it runs, into the open note's editor as well. Off keeps the key.
/// - `icloudsync-unavailable`: no backend, as in a build without the iCloud entitlement: the page says so, the switch is
///   off and can't be turned on, and nothing was created.
extension SnapshotRunner {
    func iCloudSyncScenario() {
        let sync = SyncCenter.shared
        if script == "icloudsync-unavailable" {
            run { [self] in app?.showSettings(page: .sync) }
            wait(0.8)
            run { [self] in
                sync.setEnabled(true)
                let file = AppPaths.dataDirectory.appendingPathComponent("Sync/sync-state.json")
                check(!sync.isAvailable && !sync.isEnabled && sync.status == .unavailable(SyncEngine.notSetUp)
                      && !FileManager.default.fileExists(atPath: file.path),
                      "icloudsync-unavailable: without the iCloud entitlement the page says \"\(SyncEngine.notSetUp)\", the switch stays off")
            }
            step { [self] done in
                if let v = app?.settingsWindow?.window.contentView, let img = render(v), let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("icloudsync-settings-unavailable.png"))
                    note("wrote icloudsync-settings-unavailable.png")
                }
                done()
            }
            return
        }
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

        /// What every Mac sent, decrypted with the group key from the first Mac's keychain.
        func uploaded() -> String {
            guard let database, let state = try? database.withState({ $0 }),
                  let group = state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.group).first,
                  let key = try? FolderSyncKeyStore(folder: firstKeychain).key(group: group.group) else { return "" }
            let ops = state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.envelope)
                .flatMap { (try? $0.open(group: group.group, key: key)) ?? [] }
            return String(decoding: (try? JSONEncoder().encode(ops)) ?? Data(), as: UTF8.self)
        }
        func waitFor(_ what: String, timeout: Double = 30, _ condition: @escaping () -> Bool) {
            step { [self] done in
                waitUntil(condition, timeout: timeout) { [self] in
                    if !condition() { note("FAIL \(script): timed out waiting for \(what) (status \(sync.status))") }
                    done()
                }
            }
        }
        func settingsShot(_ name: String, sheet: Bool = false) {
            step { [self] done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                    let window = sheet ? app?.settingsWindow?.window.attachedSheet : app?.settingsWindow?.window
                    if let v = window?.contentView, let img = render(v), let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: dir.appendingPathComponent(name + ".png"))
                        note("wrote \(name).png")
                    } else {
                        note("FAIL \(script): no \(sheet ? "sheet" : "Settings window") to render for \(name)")
                    }
                    done()
                }
            }
        }
        func spaceNamed(_ name: String) -> Space? { c.store.orderedSpaces.first { $0.name == name } }
        /// The group and its key, from the first Mac's keychain.
        func groupKey() -> (UUID, SymmetricKey)? {
            guard let database, let state = try? database.withState({ $0 }),
                  let group = state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.group).first,
                  let key = try? FolderSyncKeyStore(folder: firstKeychain).key(group: group.group) else { return nil }
            return (group.group, key)
        }
        /// Every note version in iCloud, opened.
        func noteVersions() -> [SyncNoteVersion] {
            guard let gk = groupKey(), let state = try? database?.withState({ $0 }) else { return [] }
            return state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.note).compactMap { try? $0.open(group: gk.0, key: gk.1) }
        }
        func recordCount(_ type: String) -> Int {
            ((try? database?.withState { $0 })?.records(zone: SyncCloudSchema.zone) ?? []).filter { $0.type == type }.count
        }
        /// The synthetic picture the first Mac's note shows (drawn here, never anyone's data).
        func notePicture() -> NoteImage? {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 64, height: 40).fill()
            NSColor.white.setFill(); NSRect(x: 8, y: 8, width: 30, height: 24).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:]).flatMap { NoteImages.store($0, ext: "png") }
        }
        func noteNamed(_ title: String) -> Note? { c.store.state.notes.values.first { $0.displayTitle == title } }
        func pinnedNote(_ title: String, in space: Space?) -> Item? {
            guard let n = noteNamed(title) else { return nil }
            return c.store.state.items.values.first { $0.savedURL == n.url && $0.spaceID == space?.id }
        }
        func copyKeys() {
            let fm = FileManager.default
            try? fm.createDirectory(at: keychain, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: firstKeychain, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.copyItem(at: file, to: keychain.appendingPathComponent(file.lastPathComponent))
            }
        }

        switch script {
        case "icloudsync":
            var privateWindow: PrivateWindowController?
            var littleArc: LittleArcController?
            run { [self] in
                do {
                    let work = try c.store.createSpace(name: "Work", icon: .emoji("💼"))
                    let docs = try c.store.createFolder(named: "Docs", inSpace: work.id)
                    try pin("https://example.com/docs", title: "Docs home", icon: nil, space: work.id, parent: docs.id)
                    try pin("https://example.com/board", title: "Board", icon: nil, space: work.id)
                    try favorite("https://mail.example.com/", title: "Mail", icon: nil, profile: c.store.defaultProfile.id, space: work.id)
                    _ = try c.store.openTab(url: "https://today.example/secret-today", inSpace: work.id, activate: false, title: "Today only")
                    // A second profile: the other Macs map it on their first-sync screen.
                    let studio = try c.profiles.createProfile(name: "Studio", emoji: "🎨", color: nil)
                    let design = try c.store.createSpace(name: "Design", icon: .emoji("🎨"), profileID: studio.id)
                    try pin("https://example.net/moodboard", title: "Moodboard", icon: nil, space: design.id)
                    // P14b1: a pinned note with a title, text and a picture, in the Docs folder; and a note in Today.
                    let note = try c.store.createNote(inSpace: work.id, parentID: docs.id)
                    let id = NoteURL.noteID(note.url)!
                    var blocks = [NoteBlock(kind: .heading1, runs: [NoteRun("Launch checklist")]),
                                  NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Write the release notes")])]
                    if let picture = notePicture() { blocks.append(NoteBlock(runs: [NoteRun(image: picture)])) }
                    c.store.updateNote(id, document: NoteDocument(blocks: blocks))
                    try c.store.setNoteTitle(id, "Launch plan")
                    let today = try c.store.createNote(inSpace: work.id, pinned: false)
                    c.store.updateNote(NoteURL.noteID(today.url)!, document: NoteDocument(lines: ["Scratch only here"]))
                    c.switchToSpace(work.id, animated: false)
                } catch { note("FAIL icloudsync: seeding: \(error)") }
                littleArc = app?.openLittleArc(url: URL(string: "https://littlearc.example/secret-little"))
                if let app { PrivateBrowsing.shared.open(app: app) { w in
                    privateWindow = w
                    _ = w?.openPage(URL(string: "https://private.example/secret-private"))
                } }
            }
            wait(1)
            run { [self] in app?.showSettings(page: .sync) }
            settingsShot("icloudsync-settings-off")
            run { [self] in
                check(sync.isAvailable && sync.backend == .mock(mock) && !sync.isEnabled && sync.status == .off,
                      "icloudsync: Settings → Sync is there with the mock CloudKit backend, off by default (\(sync.status))")
                check(!sync.isScheduling && !sync.hasTransport, "icloudsync: off: no transport, timer, observers or push registration")
                sync.setEnabled(true)
            }
            waitFor("the first upload") { sync.status == .upToDate }
            run { [self] in
                let sent = uploaded()
                let batches = (try? database?.withState { $0.batchCount }) ?? 0
                check(batches > 0 && sent.contains("example.com\\/docs") && sent.contains("mail.example.com"),
                      "icloudsync: the first Mac made the group and sent its sidebar (\(batches) batches)")
                let leaked = ["secret-today", "Today only", "secret-private", "private.example", "secret-little", "littlearc.example"]
                    .filter(sent.contains)
                check(privateWindow != nil && littleArc != nil && leaked.isEmpty,
                      "icloudsync: nothing of a Today tab, a private window or Little Arc was sent (private window \(privateWindow != nil), "
                      + "Little Arc \(littleArc != nil), leaked: \(leaked))")
                check(sync.devices.map(\.isThisMac) == [true], "icloudsync: the device list has this Mac (\(sync.devices.map(\.name)))")
                let versions = noteVersions()
                let raw = (try? database?.withState { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }) ?? ""
                check(versions.count == 1 && versions.first?.title == "Launch plan"
                      && versions.first?.document?.plainText.contains("Write the release notes") == true
                      && recordCount(SyncCloudSchema.noteAsset) == 1 && sent.contains("airc-note:"),
                      "icloudsync: the pinned note went up: its row, its sealed text and title, its picture (\(versions.count) notes, "
                      + "\(recordCount(SyncCloudSchema.noteAsset)) pictures)")
                check(!["Launch plan", "Launch checklist", "release notes", "Scratch only here"].contains(where: raw.contains)
                      && !versions.contains { $0.document?.plainText.contains("Scratch only here") == true },
                      "icloudsync: nothing of a note is readable in iCloud, and the note in Today stayed on this Mac")
            }
            settingsShot("icloudsync-settings-on")
            run { privateWindow?.closeWindow(); littleArc?.closeWindow() }
            wait(0.5)

        case "icloudsync-second", "icloudsync-replace":
            let replace = script == "icloudsync-replace"
            var backups = 0
            run { [self] in
                do {
                    let mine = try c.store.createSpace(name: replace ? "Old" : "Laptop")
                    try pin(replace ? "https://old.example/pinned" : "https://example.org/laptop", title: "Mine", icon: nil, space: mine.id)
                    if replace {
                        _ = try c.store.openTab(url: "https://old.example/today", inSpace: mine.id, activate: false)
                        // Replace keeps this Mac's pinned notes, with their Space (P14b1).
                        let notebook = try c.store.createSpace(name: "Notebook")
                        let n = try c.store.createNote(inSpace: notebook.id)
                        c.store.updateNote(NoteURL.noteID(n.url)!, document: NoteDocument(lines: ["Kept by Replace", "only on the third Mac"]))
                    }
                } catch { note("FAIL \(script): seeding: \(error)") }
                backups = (try? FileManager.default.contentsOfDirectory(atPath: app!.settings.backupDirectory.path))?.count ?? 0
                app?.showSettings(page: .sync)
                sync.setEnabled(true)
            }
            waitFor("waiting for iCloud Keychain") { sync.status == .waitingForKeychain }
            run { [self] in
                check(sync.status == .waitingForKeychain && spaceNamed("Work") == nil,
                      "\(script): the group is in iCloud and its key isn't here yet: waiting for iCloud Keychain, nothing changed")
            }
            if !replace { settingsShot("icloudsync-settings-waiting") }
            run { copyKeys(); sync.syncNow() }
            waitFor("the first-sync screen") { sync.firstSync != nil }
            wait(0.6)
            run { [self] in
                let f = sync.firstSync
                check(f?.iCloud.spaces.contains { $0.hasPrefix("Work") } == true && f?.thisMac.spaces.contains(replace ? "Old" : "Laptop") == true
                      && app?.settingsWindow?.window.attachedSheet != nil,
                      "\(script): the first-sync screen shows both sidebars (iCloud \(f?.iCloud.spaces ?? []), this Mac \(f?.thisMac.spaces ?? []))")
                check(f?.profiles.map(\.name) == ["Studio"] && f?.profiles.first?.spaces == ["Design"],
                      "\(script): it asks about the other Mac's Studio profile, used by Design (\(f?.profiles.map(\.name) ?? []))")
            }
            if !replace { settingsShot("icloudsync-first-sync", sheet: true) }
            run { sync.choose(replace ? .replace : .merge, profiles: [:]) }
            waitFor("the first sync") { sync.status == .upToDate }
            wait(0.4)
            run { [self] in
                let store = c.store
                let backup = sync.lastBackup.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                let nowBackups = (try? FileManager.default.contentsOfDirectory(atPath: app!.settings.backupDirectory.path))?.count ?? 0
                check(nowBackups == backups + 1 && backup.contains(replace ? "old.example" : "example.org"),
                      "\(script): a backup of this Mac's sidebar first (\(sync.lastBackup?.lastPathComponent ?? "none"))")
                let work = store.orderedSpaces.first { $0.name.hasPrefix("Work") }
                let docs = store.state.items.values.first { $0.title == "Docs" && $0.spaceID == work?.id }
                let inDocs = store.state.items.values.contains { $0.savedURL == "https://example.com/docs" && $0.parentID == docs?.id }
                let mail = store.favorites(ofProfile: store.defaultProfile.id).contains { $0.savedURL == "https://mail.example.com/" }
                check(work != nil && inDocs && mail, "\(script): the first Mac's Space, folder, pinned tab and Favorite are here")
                let design = spaceNamed("Design")
                let studio = store.profile(design?.profileID)
                check(studio?.name == "Studio" && studio?.id != store.defaultProfile.id && studio?.googleAccount == nil,
                      "\(script): Design uses a new, empty Studio profile here (\(studio?.name ?? "none"))")
                let note = noteNamed("Launch plan")
                let picture = note?.document.imageFiles.first
                check(pinnedNote("Launch plan", in: work)?.parentID == docs?.id && docs != nil
                      && note?.document.plainText.contains("Write the release notes") == true
                      && picture.flatMap(NoteImages.url).map { FileManager.default.fileExists(atPath: $0.path) } == true,
                      "\(script): the first Mac's pinned note is here, in Docs, with its title, text and picture (\(note?.displayTitle ?? "none"))")
                check(!c.store.state.notes.values.contains { $0.document.plainText.contains("Scratch only here") },
                      "\(script): the first Mac's note in Today didn't come")
                if replace {
                    let kept = spaceNamed("Notebook")
                    check(pinnedNote("Kept by Replace", in: kept) != nil
                          && noteVersions().contains { $0.document?.plainText.contains("only on the third Mac") == true },
                          "icloudsync-replace: Replace kept this Mac's pinned note and its Space, and sent them")
                    let sent = uploaded()
                    check(spaceNamed("Old") == nil && store.state.archive.values.contains { $0.url == "https://old.example/today" }
                          && !sent.contains("old.example"),
                          "icloudsync-replace: Replace took iCloud's sidebar; its own Space is gone (Today tab archived), none of it sent")
                    check(spaceNamed("Laptop") != nil, "icloudsync-replace: the second Mac's Space came too")
                } else {
                    check(spaceNamed("Laptop") != nil, "icloudsync-second: Merge kept this Mac's own Space")
                    if let work { c.switchToSpace(work.id, animated: false) }
                }
            }
            if !replace {
                capture("icloudsync-second-sidebar")
                var sent = false
                run { [self] in
                    guard let work = c.store.orderedSpaces.first(where: { $0.name == "Work" }) else { return }
                    try? c.store.updateSpace(work.id) { $0.name = "Work (synced)" }
                    try? pin("https://example.org/from-second", title: "From the second Mac", icon: nil, space: work.id)
                    if let n = noteNamed("Launch plan") {
                        c.store.updateNote(n.id, document: NoteDocument(blocks: n.document.blocks + [NoteBlock(kind: .checkbox, runs: [NoteRun("Added on the second Mac")])]))
                    }
                    sync.syncNow { sent = true }
                }
                waitFor("the second Mac's edits to go up") { sent && sync.status == .upToDate }
                run { [self] in
                    check(uploaded().contains("Work (synced)") && uploaded().contains("example.org\\/from-second"),
                          "icloudsync-second: a rename and a new pinned tab went up")
                    check(noteVersions().contains { $0.document?.plainText.contains("Added on the second Mac") == true },
                          "icloudsync-second: the note's edit went up")
                }
                settingsShot("icloudsync-settings-two-macs")
            }

        case "icloudsync-return":
            run { [self] in check(sync.isEnabled, "icloudsync-return: still on after a relaunch") }
            waitFor("the launch sync") { sync.status == .upToDate && spaceNamed("Work (synced)") != nil }
            run { [self] in
                let work = spaceNamed("Work (synced)")
                let pinned = c.store.state.items.values.contains { $0.savedURL == "https://example.org/from-second" && $0.spaceID == work?.id }
                check(work != nil && pinned && spaceNamed("Laptop") != nil,
                      "icloudsync-return: the second Mac's Space, rename and pinned tab arrived (\(c.store.orderedSpaces.map(\.name)))")
                check(noteNamed("Launch plan")?.document.plainText.contains("Added on the second Mac") == true
                      && pinnedNote("Kept by Replace", in: spaceNamed("Notebook")) != nil,
                      "icloudsync-return: the second Mac's note edit and the third Mac's kept note arrived")
                // Another Mac's edit, then its push: it shows without a relaunch.
                guard let work, let database, let state = try? database.withState({ $0 }),
                      let group = state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.group).first,
                      let key = try? FolderSyncKeyStore(folder: firstKeychain).key(group: group.group) else {
                    return note("FAIL icloudsync-return: no group to write to")
                }
                var other = SyncReplica()
                let device = other.clock.device
                guard let op = try? other.edit(.init(.space, work.id), [.name: .text("Work (live)")], now: Int64(Date().timeIntervalSince1970 * 1000)),
                      let envelope = try? SyncEnvelope.seal([op], group: group.group, device: device, key: key) else {
                    return note("FAIL icloudsync-return: couldn't make the other Mac's edit")
                }
                c.switchToSpace(work.id, animated: false)
                // The same Mac also edits the note, which is open here: the editor shows it without a relaunch.
                var noteRecord: SyncNoteRecord?
                if let n = noteNamed("Launch plan"), let row = pinnedNote("Launch plan", in: work) {
                    if let tab = c.store.liveTab(forItem: row.id) { c.show(tab.id) } else if let t = try? c.store.openItem(row.id, inSpace: work.id) { c.show(t.id) }
                    let ms = Int64(Date().timeIntervalSince1970 * 1000)
                    let known = noteVersions().filter { $0.note == n.id }.reduce(SyncNoteVector()) { $0.merged($1.vector) }
                    let version = SyncNoteVersion(note: n.id, stamp: SyncStamp(milliseconds: ms, device: device), vector: known.incremented(device),
                                                  removed: false, title: n.title,
                                                  document: NoteDocument(blocks: n.document.blocks + [NoteBlock(runs: [NoteRun("Pushed from another Mac")])]),
                                                  created: n.createdAt, updated: Date())
                    noteRecord = try? SyncNoteRecord.seal(version, group: group.group, device: device, key: key)
                }
                Task { @MainActor in
                    let t = CloudKitSyncTransport(database: database, device: device)
                    try? await t.append(envelope)
                    if let noteRecord { try? await t.saveNote(noteRecord) }
                    sync.remoteNotification(["ck": ["ce": 2]])
                }
            }
            waitFor("the pushed change", timeout: 15) {
                spaceNamed("Work (live)") != nil && noteNamed("Launch plan")?.document.plainText.contains("Pushed from another Mac") == true
            }
            run { [self] in check(spaceNamed("Work (live)") != nil, "icloudsync-return: a push brought another Mac's rename in while running") }
            run { [self] in
                let open = noteNamed("Launch plan").flatMap { NoteCenter.shared.existingEditor($0.id) }
                check(open?.textView.string.contains("Pushed from another Mac") == true,
                      "icloudsync-return: the push brought the note's edit into its open editor (\(open == nil ? "no editor" : "editor open"))")
            }
            capture("icloudsync-return-sidebar")
            run { [self] in
                sync.setEnabled(false)
                let keys = (try? FileManager.default.contentsOfDirectory(atPath: firstKeychain.path)) ?? []
                check(sync.status == .off && !keys.isEmpty, "icloudsync-return: off keeps the group key (\(keys.count) in the keychain)")
                check(!sync.isScheduling && !sync.hasTransport, "icloudsync-return: off removes the transport, timer, observers and push registration")
            }

        default:
            note("FAIL unknown sync script \(script)")
        }
    }
}
#endif
