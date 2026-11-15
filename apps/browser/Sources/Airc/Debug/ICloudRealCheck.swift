// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import CryptoKit

/// The real-iCloud test (docs/sync.md, "The real iCloud test"): a Developer ID-signed test build with the provisioning
/// profile, two installations (data folders) on one Mac and Apple Account, the real CloudKit container (Production),
/// in a zone of the test's own (`--sync-cloudkit-test-zone AircSidebarTest…`). Its group key is a local,
/// not-synchronizable item under a keychain service of its own, in the profile's access group: nothing reaches the
/// owner's other devices. Not in the suite: it needs the profile and the deployed schema.
///
/// - `icloudsync-real-a`: the first installation uploads a test Space, with a pinned note (title, text, a drawn
///   picture) and a note in Today (P14b1).
/// - `icloudsync-real-b`: the second finds it (the key is already in this Mac's keychain), merges, edits.
/// - `icloudsync-real-live-a` and `icloudsync-real-live-b` (notes deployed): both installations at once, taking turns
///   through files in `AIRC_SYNC_REAL_HANDSHAKE`: B's edit arrives in A's open editor, then both edit the note apart
///   (A by typing in its editor) and every installation ends with the later text and B's as a conflicted copy.
/// - Splits (P14b2), in real-a, real-b and cleanup: A saves a pinned split (two panes, stacked, 30/70) in its test
///   Space; its operations go up in version 3 batches, nothing readable. B gets it with its panes in order and its
///   layout, renames it, turns it side by side and adds a pane; A gets all of that.
/// - `icloudsync-real-cleanup`: the first gets the edits, checks nothing readable is in the zone, then the test zone
///   (all its records and its subscription) and the test key are deleted, whatever happened before.
///
/// With `AIRC_SYNC_REAL_INVENTORY=1`, `icloudsync-real-cleanup` instead lists every zone of the container's private
/// database (records, field and asset bytes per type), its subscriptions and the test keychain items, read only; with
/// `AIRC_SYNC_REAL_DELETE=1` too, it then deletes only zones named `AircSidebarTest…`, test subscriptions and the test
/// keychain services' items, and lists again. The real `AircSidebar` zone, its subscription and the product's key
/// service are never written (docs/sync.md, "Test zones and storage").
///
/// Notes need their record types in the Production schema (docs/sync.md, "Deploying the schema"). With
/// `AIRC_SYNC_NOTES_SCHEMA=deployed` the notes go both ways; without it the check expects what a container
/// without them does: notes wait (`notesHeld`), the note's row and everything else still sync.
extension SnapshotRunner {
    func iCloudRealScenario() {
        let sync = SyncCenter.shared
        func waitFor(_ what: String, timeout: Double = 90, _ condition: @escaping () -> Bool) {
            step { [self] done in
                waitUntil(condition, timeout: timeout) { [self] in
                    if !condition() { note("FAIL \(script): timed out waiting for \(what) (status \(sync.status))") }
                    done()
                }
            }
        }
        /// Like `waitFor`, with a sync cycle every few seconds (no pushes in the test build: its profile has no
        /// push entitlement, and the fallback timer is ten minutes).
        func syncUntil(_ what: String, timeout: Double = 90, _ condition: @escaping () -> Bool) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(timeout)
                func cycle() {
                    if condition() { return done() }
                    if Date() > deadline { note("FAIL \(script): timed out waiting for \(what) (status \(sync.status))"); return done() }
                    sync.syncNow { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { cycle() } }
                }
                cycle()
            }
        }
        func spaceNamed(_ name: String) -> Space? { c.store.orderedSpaces.first { $0.name == name } }
        func pinned(_ url: String, in space: Space?) -> Bool {
            c.store.state.items.values.contains { $0.savedURL == url && $0.spaceID == space?.id }
        }
        let notesDeployed = ProcessInfo.processInfo.environment["AIRC_SYNC_NOTES_SCHEMA"] == "deployed"
        let title = "iCloud plan", copyPrefix = "iCloud plan (conflicted copy"
        /// What the test writes: none of it may be readable in iCloud.
        let secrets = [title, "iCloud note test", "written on A", "edited on B", "live from B", "conflict from A", "conflict from B",
                       "Scratch only on A", "iCloud test A", "icloud-test-a", "icloud-test-b", "example.com", "conflicted copy",
                       "iCloud split", "icloud-split-"]
        let splitTitle = "iCloud split A", splitEdited = "iCloud split (from B)"
        let splitURLs = ["https://example.com/icloud-split-left", "https://example.com/icloud-split-right"]
        let splitAdded = "https://example.com/icloud-split-b"
        func splitNamed(_ name: String) -> Item? { c.store.state.items.values.first { $0.kind == .split && $0.title == name } }
        func paneURLs(_ s: Item?) -> [String] { s.map { c.store.panes(ofSplitItem: $0.id).compactMap(\.savedURL) } ?? [] }
        /// A pinned split of `urls` in `space`, saved without keeping its pages open.
        func saveSplit(_ urls: [String], title: String, space: String) throws {
            let tabs = try urls.map { try c.store.openTab(url: $0, inSpace: space, activate: false) }
            let x = try c.store.createSplit(tabs.map(\.id), inSpace: space, axis: .vertical, focused: tabs[0].id)
            c.store.setSplitFractions(x.id, [0.3, 0.7])
            try c.store.move(.split(x.id), to: .pinned(spaceID: space, parentID: nil, index: 0))
            try c.store.renameItem(x.id, to: title)
            _ = try c.store.closeTab(tabs[0].id)
        }
        func firstShare(_ s: Item?) -> Double? {
            guard let s, let layout = s.splitLayout else { return nil }
            return layout.fractions(c.store.panes(ofSplitItem: s.id).map(\.id)).first
        }
        /// How many split rows the zone's batches create, and the versions of the batches with and without them.
        func splitBatches(_ z: Zone) -> (splits: Int, versions: Set<Int>, others: Set<Int>) {
            guard let g = z.group, let k = z.key else { return (0, [], []) }
            var splits = 0, versions = Set<Int>(), others = Set<Int>()
            for e in z.records.compactMap(SyncCloudSchema.envelope) {
                guard let ops = try? e.open(group: g, key: k) else { continue }
                let n = ops.filter { $0.fields[.kind] == .text("split") }.count
                splits += n
                if n > 0 { versions.insert(e.version) } else { others.insert(e.version) }
            }
            return (splits, versions, others)
        }
        func noteNamed(_ name: String) -> Note? { c.store.state.notes.values.first { $0.displayTitle == name } }
        func noteRow(_ n: Note?) -> Item? {
            guard let n else { return nil }
            return c.store.state.items.values.first { $0.savedURL == n.url && $0.spaceID != nil }
        }
        /// The test note's row in `space`, and its text here (before notes deployed: any note row).
        func testNote(in space: Space?) -> (row: Item?, text: String?) {
            if notesDeployed, let n = noteNamed(title) {
                let row = noteRow(n)
                return (row?.spaceID == space?.id ? row : nil, n.document.plainText)
            }
            let row = c.store.state.items.values.first { NoteURL.isNote($0.savedURL) && $0.spaceID == space?.id }
            return (row, c.store.note(NoteURL.noteID(row?.savedURL))?.document.plainText)
        }
        func pictureHere(_ n: Note?) -> Bool {
            guard let file = n?.document.imageFiles.first, let url = NoteImages.url(file) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        /// The synthetic picture A's note shows (drawn here, never anyone's data).
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

        /// Everything in the test zone, read straight from CloudKit (pictures fetched by name, with their bytes), and the
        /// group key from this installation's keychain.
        struct Zone { var records: [SyncCloudRecord] = []; var group: UUID?; var key: SymmetricKey?; var error: String? }
        func readZone(_ done: @escaping (Zone) -> Void) {
            guard let container = SyncCapability.container, let zone = sync.cloudTestZone, let keys = sync.keyStore else {
                return done(Zone(error: "no container, zone or keychain"))
            }
            let database = CloudKitSyncDatabase(container: container)
            Task { @MainActor in
                var z = Zone()
                do {
                    var token: Data?
                    var more = true
                    while more {
                        let changes = try await database.fetchChanges(zone: zone, since: token)
                        z.records += changes.changed
                        token = changes.token; more = changes.moreComing
                    }
                    let assets = z.records.filter { $0.type == SyncCloudSchema.noteAsset }.map(\.name)
                    if !assets.isEmpty {
                        let full = try await database.fetch(assets, zone: zone)
                        z.records = z.records.filter { $0.type != SyncCloudSchema.noteAsset } + full
                    }
                    z.group = z.records.compactMap(SyncCloudSchema.group).first?.group
                    if let g = z.group { z.key = try keys.key(group: g) }
                } catch { z.error = "\(error)" }
                done(z)
            }
        }
        func versions(_ z: Zone) -> [SyncNoteVersion] {
            guard let g = z.group, let k = z.key else { return [] }
            return z.records.compactMap(SyncCloudSchema.note).compactMap { try? $0.open(group: g, key: k) }
        }
        /// The sidebar operations in the zone, opened, as JSON.
        func openedBatches(_ z: Zone) -> String {
            guard let g = z.group, let k = z.key else { return "" }
            let ops = z.records.compactMap(SyncCloudSchema.envelope).flatMap { (try? $0.open(group: g, key: k)) ?? [] }
            return (try? JSONEncoder().encode(ops)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        /// Any of `secrets` in a record's fields as stored (strings, and bytes and assets read as text), or a picture's
        /// bytes as they are on this Mac.
        func readable(_ z: Zone, pictures: [Data]) -> [String] {
            var found: [String] = []
            for r in z.records {
                for (name, value) in r.fields {
                    let raw: Data
                    switch value {
                    case .string(let s): raw = Data(s.utf8)
                    case .bytes(let d), .asset(let d): raw = d
                    case .int, .date: continue
                    }
                    let text = String(decoding: raw, as: UTF8.self)
                    for s in secrets where text.contains(s) { found.append("\(r.type).\(name): \(s)") }
                    if raw.starts(with: [0x89, 0x50, 0x4E, 0x47]) || pictures.contains(where: { !$0.isEmpty && raw.range(of: $0) != nil }) {
                        found.append("\(r.type).\(name): a picture's bytes")
                    }
                }
            }
            return found
        }
        func picturesHere() -> [Data] {
            c.store.noteImageFiles.compactMap { NoteImages.url($0).flatMap { try? Data(contentsOf: $0) } }
        }

        // The live pair's turns: empty files in a folder both installations share.
        let handshake = ProcessInfo.processInfo.environment["AIRC_SYNC_REAL_HANDSHAKE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        func signal(_ name: String) {
            guard let handshake else { return }
            try? FileManager.default.createDirectory(at: handshake, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: handshake.appendingPathComponent(name).path, contents: Data())
        }
        func awaitSignal(_ name: String, timeout: Double = 100) {
            waitFor("the other installation's \"\(name)\"", timeout: timeout) {
                handshake.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } ?? false
            }
        }
        func editor() -> NoteEditor? { noteNamed(title).flatMap { NoteCenter.shared.existingEditor($0.id) } }

        run { [self] in
            check(sync.backend == .cloudKit(container: "iCloud.com.aircbrowser.Airc") && sync.cloudTestZone?.hasPrefix("AircSidebarTest") == true,
                  "\(script): the real CloudKit container, in the test zone \(sync.cloudTestZone ?? "none") (backend \(sync.backend))")
        }
        if script == "icloudsync-real-cleanup", ProcessInfo.processInfo.environment["AIRC_SYNC_REAL_INVENTORY"] == "1" {
            return iCloudInventory(delete: ProcessInfo.processInfo.environment["AIRC_SYNC_REAL_DELETE"] == "1")
        }
        switch script {
        case "icloudsync-real-a":
            run { [self] in
                check(sync.cloudDatabasesMade == 0 && !sync.isScheduling && !sync.hasTransport,
                      "icloudsync-real-a: with the entitlement and sync off, no CloudKit container, transport, timer or push registration")
                do {
                    let s = try c.store.createSpace(name: "iCloud test A", icon: .emoji("🧪"))
                    try pin("https://example.com/icloud-test-a", title: "Test A", icon: nil, space: s.id)
                    try saveSplit(splitURLs, title: splitTitle, space: s.id)
                    let n = try c.store.createNote(inSpace: s.id)
                    let id = NoteURL.noteID(n.url)!
                    var blocks = [NoteBlock(runs: [NoteRun("iCloud note test")]), NoteBlock(runs: [NoteRun("written on A")])]
                    if notesDeployed, let picture = notePicture() { blocks.append(NoteBlock(runs: [NoteRun(image: picture)])) }
                    c.store.updateNote(id, document: NoteDocument(blocks: blocks))
                    if notesDeployed {
                        try c.store.setNoteTitle(id, title)
                        let today = try c.store.createNote(inSpace: s.id, pinned: false)
                        c.store.updateNote(NoteURL.noteID(today.url)!, document: NoteDocument(lines: ["Scratch only on A"]))
                    }
                } catch { note("FAIL \(script): seeding: \(error)") }
                sync.setEnabled(true)
            }
            waitFor("the first upload") { sync.status == .upToDate }
            run { [self] in
                check(sync.status == .upToDate && sync.devices.contains { $0.isThisMac },
                      "icloudsync-real-a: made the group, saved its key to the keychain (local test item) and uploaded (\(sync.devices.count) device)")
                check(sync.notesHeld == !notesDeployed,
                      notesDeployed ? "icloudsync-real-a: notes aren't held (schema deployed)"
                                    : "icloudsync-real-a: Production refuses notes (schema not deployed): they wait, and the sidebar synced")
            }
            var splitZone = Zone()
            step { done in readZone { splitZone = $0; done() } }
            run { [self] in
                let b = splitBatches(splitZone), leaks = readable(splitZone, pictures: [])
                check(splitZone.error == nil && b.splits == 1 && b.versions == [SyncSplits.envelopeVersion],
                      "icloudsync-real-a: the pinned split went up in a version 3 batch only (\(b.splits) split rows, versions \(b.versions.sorted()))")
                check(splitZone.error == nil && leaks.isEmpty, "icloudsync-real-a: nothing of the split is readable in iCloud (\(leaks))")
            }
            if notesDeployed {
                var zone = Zone()
                step { done in readZone { zone = $0; done() } }
                run { [self] in
                    let vs = versions(zone)
                    let assets = zone.records.filter { $0.type == SyncCloudSchema.noteAsset }.count
                    check(zone.error == nil && vs.count == 1 && vs.first?.title == title
                          && vs.first?.document?.plainText.contains("written on A") == true
                          && vs.first?.document?.imageFiles.isEmpty == false && assets == 1
                          && openedBatches(zone).contains("airc-note:"),
                          "icloudsync-real-a: the pinned note went up: its row, its sealed text and title, its picture (\(zone.records.count) records, "
                          + "\(vs.count) notes, \(assets) pictures\(zone.error.map { ", \($0)" } ?? ""))")
                    let leaks = readable(zone, pictures: picturesHere())
                    check(zone.error == nil && leaks.isEmpty && !vs.contains { $0.document?.plainText.contains("Scratch only on A") == true },
                          "icloudsync-real-a: nothing of a note is readable in iCloud, and the note in Today stayed on this Mac (\(leaks))")
                }
            }
        case "icloudsync-real-b":
            run { sync.setEnabled(true) }
            waitFor("the first-sync screen") { sync.firstSync != nil }
            run { [self] in
                check(sync.firstSync?.iCloud.spaces.contains("iCloud test A") == true,
                      "icloudsync-real-b: found the other installation's group and key, and its Space (\(sync.firstSync?.iCloud.spaces ?? []))")
                sync.choose(.merge, profiles: [:])
            }
            waitFor("the merge") { sync.status == .upToDate }
            if notesDeployed {
                // The text comes with the cycle; the picture is fetched by name, maybe a cycle later.
                syncUntil("the note's text and picture") { noteNamed(title).map { $0.document.plainText.contains("written on A") && pictureHere($0) } == true }
            }
            var sent = false
            run { [self] in
                let space = spaceNamed("iCloud test A")
                check(space != nil && pinned("https://example.com/icloud-test-a", in: space),
                      "icloudsync-real-b: the Space and its pinned tab came through CloudKit")
                let n = testNote(in: space)
                if notesDeployed {
                    let picture = noteNamed(title).map(pictureHere) == true
                    check(n.row != nil && n.text?.contains("iCloud note test\nwritten on A") == true && picture,
                          "icloudsync-real-b: the pinned note came through CloudKit with its title, text and picture "
                          + "(\(noteNamed(title)?.displayTitle ?? "no note"), picture \(picture))")
                    check(!c.store.state.notes.values.contains { $0.document.plainText.contains("Scratch only on A") },
                          "icloudsync-real-b: the other installation's note in Today didn't come")
                    if let n = noteNamed(title) {
                        c.store.updateNote(n.id, document: NoteDocument(blocks: n.document.blocks + [NoteBlock(runs: [NoteRun("edited on B")])]))
                    }
                } else {
                    check(n.row != nil && n.text?.isEmpty != false,
                          "icloudsync-real-b: the note's row came, its text waits on A until the schema is deployed")
                }
                let split = splitNamed(splitTitle)
                check(split?.spaceID == space?.id && space != nil && paneURLs(split) == splitURLs && split?.splitLayout?.axis == .vertical
                      && abs((firstShare(split) ?? 0) - 0.3) < 0.01,
                      "icloudsync-real-b: the pinned split came through CloudKit with its panes in order and its layout "
                      + "(\(paneURLs(split).count) panes, \(split?.splitLayout?.axis.rawValue ?? "none"), \(firstShare(split) ?? 0))")
                if let space {
                    try? c.store.updateSpace(space.id) { $0.name = "iCloud test A (from B)" }
                    try? pin("https://example.com/icloud-test-b", title: "Test B", icon: nil, space: space.id)
                }
                if let split, let space {
                    do {
                        try c.store.renameItem(split.id, to: splitEdited)
                        try c.store.setSplitAxis(split.id, .horizontal)
                        let t = try c.store.openTab(url: splitAdded, inSpace: space.id, activate: false)
                        try c.store.addToSplit(split.id, tabID: t.id, focus: false)
                        _ = try c.store.closeTab(t.id)
                    } catch { note("FAIL \(script): editing the split: \(error)") }
                    check(paneURLs(splitNamed(splitEdited)) == splitURLs + [splitAdded], "icloudsync-real-b: renamed the split, side by side, a third pane")
                }
                sync.syncNow { sent = true }
            }
            waitFor("the edits to go up") { sent && sync.status == .upToDate }
            run { [self] in
                check(sync.status == .upToDate, notesDeployed ? "icloudsync-real-b: a rename, a pinned tab and the note's edit went up"
                                                              : "icloudsync-real-b: a rename and a pinned tab went up")
            }

        case "icloudsync-real-live-a":
            guard notesDeployed, handshake != nil else { note("FAIL \(script): needs AIRC_SYNC_NOTES_SCHEMA=deployed and AIRC_SYNC_REAL_HANDSHAKE"); break }
            syncUntil("B's edit at launch") { noteNamed(title)?.document.plainText.contains("edited on B") == true }
            run { [self] in
                check(noteNamed(title)?.document.plainText.contains("edited on B") == true,
                      "icloudsync-real-live-a: the note's edit on B arrived on A")
                // Open the note: its editor is up before B's next edit exists.
                if let row = noteRow(noteNamed(title)), let space = row.spaceID {
                    c.switchToSpace(space, animated: false)
                    if let tab = c.store.liveTab(forItem: row.id) { c.show(tab.id) }
                    else if let t = try? c.store.openItem(row.id, inSpace: space) { c.show(t.id) }
                }
            }
            waitFor("the note's editor", timeout: 15) { editor()?.textView.string.contains("edited on B") == true }
            run { signal("a-open") }
            awaitSignal("b-live")
            syncUntil("B's live edit", timeout: 60) { editor()?.textView.string.contains("live from B") == true }
            run { [self] in
                check(editor()?.textView.string.contains("live from B") == true,
                      "icloudsync-real-live-a: B's edit came into A's open editor, without a relaunch (\(editor() == nil ? "no editor" : "editor open"))")
                signal("a-live")
            }
            // B edits again without seeing A's next edit: the two are made apart.
            awaitSignal("b-conflict")
            var typed = false
            run { [self] in
                guard let tv = editor()?.textView else { return note("FAIL \(script): no editor to type in") }
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                tv.insertText("\nconflict from A", replacementRange: tv.selectedRange())
                typed = noteNamed(title)?.document.plainText.contains("conflict from A") == true
                check(typed, "icloudsync-real-live-a: typing in the editor changed the note (before B's version is fetched)")
                sync.syncNow { signal("a-conflict") }
            }
            awaitSignal("b-copy")
            syncUntil("B's conflicted copy", timeout: 60) { [self] in c.store.state.notes.values.contains { $0.displayTitle.hasPrefix(copyPrefix) } }
            run { [self] in
                let n = noteNamed(title), copy = c.store.state.notes.values.first { $0.displayTitle.hasPrefix(copyPrefix) }
                check(n?.document.plainText.contains("conflict from A") == true && n?.document.plainText.contains("conflict from B") == false
                      && editor()?.textView.string.contains("conflict from A") == true,
                      "icloudsync-real-live-a: edits made apart: the later one (A's typing) stays, in the note and its open editor")
                check(copy?.document.plainText.contains("conflict from B") == true && noteRow(copy)?.spaceID == noteRow(n)?.spaceID && noteRow(copy) != nil,
                      "icloudsync-real-live-a: B's losing text came as a pinned note of its own (\(copy?.displayTitle ?? "none"))")
                signal("a-done")
            }

        case "icloudsync-real-live-b":
            guard notesDeployed, handshake != nil else { note("FAIL \(script): needs AIRC_SYNC_NOTES_SCHEMA=deployed and AIRC_SYNC_REAL_HANDSHAKE"); break }
            waitFor("the launch sync") { sync.status == .upToDate && noteNamed(title) != nil }
            awaitSignal("a-open")
            var sent = false
            run { [self] in
                guard let n = noteNamed(title) else { return note("FAIL \(script): no note") }
                c.store.updateNote(n.id, document: NoteDocument(blocks: n.document.blocks + [NoteBlock(runs: [NoteRun("live from B")])]))
                sync.syncNow { sent = true }
            }
            waitFor("the live edit to go up") { sent && sync.status == .upToDate }
            run { signal("b-live") }
            awaitSignal("a-live")
            var sent2 = false
            run { [self] in
                guard let n = noteNamed(title) else { return note("FAIL \(script): no note") }
                c.store.updateNote(n.id, document: NoteDocument(blocks: n.document.blocks + [NoteBlock(runs: [NoteRun("conflict from B")])]))
                sync.syncNow { sent2 = true }
            }
            waitFor("B's conflicting edit to go up") { sent2 && sync.status == .upToDate }
            run { signal("b-conflict") }
            awaitSignal("a-conflict")
            syncUntil("A's later edit", timeout: 60) { noteNamed(title)?.document.plainText.contains("conflict from A") == true }
            run { [self] in
                let n = noteNamed(title), copy = c.store.state.notes.values.first { $0.displayTitle.hasPrefix(copyPrefix) }
                check(n?.document.plainText.contains("conflict from A") == true && n?.document.plainText.contains("conflict from B") == false,
                      "icloudsync-real-live-b: edits made apart: B takes A's later text")
                check(copy?.document.plainText.contains("conflict from B") == true && noteRow(copy) != nil,
                      "icloudsync-real-live-b: B's own losing text stays, as \"\(copy?.displayTitle ?? "no copy")\"")
            }
            var sent3 = false
            run { sync.syncNow { sent3 = true } }
            waitFor("the conflicted copy to go up") { sent3 && sync.status == .upToDate }
            run { signal("b-copy") }
            awaitSignal("a-done")

        case "icloudsync-real-cleanup":
            // The device list is refreshed at the end of a cycle, after the edits are applied: wait for both.
            waitFor("the other installation's edits", timeout: 60) { spaceNamed("iCloud test A (from B)") != nil && sync.devices.count == 2 }
            run { [self] in
                let space = spaceNamed("iCloud test A (from B)")
                check(space != nil && pinned("https://example.com/icloud-test-b", in: space) && sync.devices.count == 2,
                      "icloudsync-real-cleanup: the other installation's rename and pinned tab arrived; \(sync.devices.count) devices")
                if notesDeployed {
                    check(testNote(in: space).text?.contains("edited on B") == true, "icloudsync-real-cleanup: the note's edit on B is here")
                }
                let split = splitNamed(splitEdited)
                check(split?.spaceID == space?.id && space != nil && paneURLs(split) == splitURLs + [splitAdded] && split?.splitLayout?.axis == .horizontal
                      && c.store.state.items.values.filter({ $0.kind == .split }).count == 1,
                      "icloudsync-real-cleanup: B's split edits arrived: its name, side by side, the third pane last "
                      + "(\(split?.title ?? "no split"), \(paneURLs(split).count) panes, \(split?.splitLayout?.axis.rawValue ?? "none"))")
            }
            var cleanupZone = Zone()
            step { done in readZone { cleanupZone = $0; done() } }
            run { [self] in
                let leaks = readable(cleanupZone, pictures: [])
                check(cleanupZone.error == nil && !cleanupZone.records.isEmpty && leaks.isEmpty && splitBatches(cleanupZone).versions == [SyncSplits.envelopeVersion],
                      "icloudsync-real-cleanup: after both installations' split edits, nothing readable in the zone, split rows only in version 3 batches (\(leaks))")
            }
            if notesDeployed {
                var zone = Zone()
                step { done in readZone { zone = $0; done() } }
                run { [self] in
                    let vs = versions(zone), leaks = readable(zone, pictures: picturesHere())
                    check(zone.error == nil && !zone.records.isEmpty && leaks.isEmpty
                          && !vs.contains { $0.document?.plainText.contains("Scratch only on A") == true },
                          "icloudsync-real-cleanup: after both installations' edits, nothing readable in the zone's \(zone.records.count) records, "
                          + "no Today note (\(leaks)\(zone.error.map { ", \($0)" } ?? ""))")
                }
            }
            run { [self] in
                sync.setEnabled(false)
                check(!sync.isScheduling && !sync.hasTransport && sync.cloudDatabase == nil,
                      "icloudsync-real-cleanup: off removes the transport, its CloudKit container, the timer and the push registration")
            }
            var cleaned = false
            run { [self] in
                guard let container = SyncCapability.container, let zone = sync.cloudTestZone, let keys = sync.keyStore else {
                    note("FAIL icloudsync-real-cleanup: nothing to clean up with"); cleaned = true; return
                }
                let database = CloudKitSyncDatabase(container: container)
                Task { @MainActor in
                    let transport = CloudKitSyncTransport(database: database, device: UUID(), zone: zone, backoff: [1, 4])
                    var group: UUID?
                    do { group = try await transport.group()?.group } catch { note("cleanup: reading the group: \(error)") }
                    if let group { do { try keys.removeUnused(group: group) } catch { note("FAIL cleanup: the test key: \(error)") } }
                    do { try await database.deleteTestZone(zone, subscription: SyncCenter.testSubscription) }
                    catch { note("FAIL cleanup: deleting the test zone: \(error)") }
                    let keyGone = group.map { (try? keys.key(group: $0)) == nil } ?? true
                    var zoneGone = false, subscriptionGone = false
                    do { _ = try await database.fetchChanges(zone: zone, since: nil) } catch SyncCloudFailure.zoneNotFound { zoneGone = true }
                    catch { note("cleanup: checking the zone: \(error)") }
                    do { let exists = try await database.hasSubscription(SyncCenter.testSubscription); subscriptionGone = !exists }
                    catch { note("cleanup: checking the subscription: \(error)") }
                    check(keyGone && zoneGone && subscriptionGone && group != nil,
                          "icloudsync-real-cleanup: deleted the test zone \(zone) (gone: \(zoneGone)), its subscription (gone: "
                          + "\(subscriptionGone)) and the local test key (gone: \(keyGone))")
                    cleaned = true
                }
            }
            waitFor("the cleanup", timeout: 60) { cleaned }
        default:
            note("FAIL unknown script \(script)")
        }
    }

    /// The keychain services only the real-iCloud tests use. Never `KeychainSyncKeyStore.service` (the product's key).
    static let testKeyServices = [SyncCenter.testKeychainService, ICloudTwoMacCheck.service]

    /// The test services' generic passwords in the app's access group (synchronizable or not): service and account only.
    static func testKeyItems() -> [(service: String, account: String, synchronizable: Bool)] {
        var found: [(String, String, Bool)] = []
        for service in testKeyServices where service != KeychainSyncKeyStore.service {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny, kSecUseDataProtectionKeychain as String: true,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            if let g = SyncCapability.keychainAccessGroup { q[kSecAttrAccessGroup as String] = g }
            var result: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { continue }
            for i in items {
                found.append((service, i[kSecAttrAccount as String] as? String ?? "?", (i[kSecAttrSynchronizable as String] as? Bool) ?? false))
            }
        }
        return found
    }

    static func deleteTestKeyItems() -> OSStatus {
        var worst = errSecSuccess
        for service in testKeyServices where service != KeychainSyncKeyStore.service {
            var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny, kSecUseDataProtectionKeychain as String: true]
            if let g = SyncCapability.keychainAccessGroup { q[kSecAttrAccessGroup as String] = g }
            let status = SecItemDelete(q as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { worst = status }
        }
        return worst
    }

    func iCloudInventory(delete: Bool) {
        var done = false
        run { [self] in
            guard let container = SyncCapability.container else { note("FAIL inventory: no container"); done = true; return }
            let database = CloudKitSyncDatabase(container: container)
            func mb(_ b: Int64) -> String { String(format: "%.2f MB", Double(b) / 1_000_000) }
            func list(_ phase: String) async -> [SyncZoneInventory] {
                var all: [SyncZoneInventory] = []
                do {
                    for zone in try await database.zoneNames() {
                        do {
                            let inv = try await database.inventory(zone: zone)
                            all.append(inv)
                            let types = inv.records.keys.sorted().map { "\($0) \(inv.records[$0]!) (\(mb((inv.fieldBytes[$0] ?? 0) + (inv.assetBytes[$0] ?? 0))))" }
                            note("INVENTORY \(phase) zone \(zone)\(inv.isTestZone ? " [test]" : zone == SyncCloudSchema.zone ? " [REAL, read only]" : " [other, read only]"): "
                                 + "\(inv.records.values.reduce(0, +)) records, \(mb(inv.totalBytes)); \(types.joined(separator: ", "))"
                                 + (inv.largestAssets.isEmpty ? "" : "; largest assets \(inv.largestAssets.prefix(5).map(mb))")
                                 + (inv.unreadable > 0 ? "; \(inv.unreadable) unreadable" : ""))
                        } catch { note("INVENTORY \(phase) zone \(zone): can't read (\(error))") }
                    }
                    note("INVENTORY \(phase) subscriptions: \(try await database.subscriptionIDs())")
                } catch { note("FAIL inventory \(phase): \(error)") }
                let keys = Self.testKeyItems()
                note("INVENTORY \(phase) test keychain items: \(keys.count) (\(keys.map { "\($0.service)\($0.synchronizable ? " [synchronizable]" : "")" }))")
                return all
            }
            Task { @MainActor in
                let before = await list("before")
                let tests = before.filter(\.isTestZone)
                note("INVENTORY totals: all zones \(mb(before.map(\.totalBytes).reduce(0, +))), test zones \(tests.count) "
                     + "(\(mb(tests.map(\.totalBytes).reduce(0, +)))), real \(mb(before.first { $0.zone == SyncCloudSchema.zone }?.totalBytes ?? 0))")
                if delete {
                    for inv in tests {
                        guard inv.isTestZone, inv.zone != SyncCloudSchema.zone else { continue }
                        do {
                            try await database.deleteTestZone(inv.zone, subscription: "airc-sidebar-test-changes-" + inv.zone)
                            note("DELETED test zone \(inv.zone) (\(inv.records.values.reduce(0, +)) records, \(mb(inv.totalBytes)))")
                        } catch { note("FAIL inventory: deleting \(inv.zone): \(error)") }
                    }
                    do {
                        for id in try await database.subscriptionIDs() where CloudKitSyncDatabase.isTestSubscription(id) {
                            try await database.deleteTestSubscription(id)
                            note("DELETED test subscription \(id)")
                        }
                    } catch { note("FAIL inventory: test subscriptions: \(error)") }
                    let status = Self.deleteTestKeyItems()
                    note(status == errSecSuccess ? "DELETED test keychain items (services \(Self.testKeyServices))" : "FAIL inventory: test keychain items: \(status)")
                    let after = await list("after")
                    let real = before.first { $0.zone == SyncCloudSchema.zone }, realAfter = after.first { $0.zone == SyncCloudSchema.zone }
                    check(!after.contains(where: \.isTestZone) && Self.testKeyItems().isEmpty,
                          "inventory: no test zone and no test keychain item left")
                    check(real?.records == realAfter?.records && real?.totalBytes == realAfter?.totalBytes,
                          "inventory: the real zone is unchanged (\(realAfter?.records.values.reduce(0, +) ?? 0) records)")
                }
                done = true
            }
        }
        step { [self] finish in waitUntil({ done }, timeout: 600) { finish() } }
    }
}
#endif
