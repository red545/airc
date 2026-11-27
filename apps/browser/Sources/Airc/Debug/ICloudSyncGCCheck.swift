// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import CryptoKit

/// `--script icloudsync-gc-a`, `-b`, `-c`, `-a2`, `-b2`, `-c2`, `-a3`, `-b3`, `-c3` (docs/sync.md "Clean-up", syncgc),
/// both engines: three app instances share a mock CloudKit database in a folder (`--sync-mock`), each with its own fake
/// keychain (`--sync-keychain`; a copied key file plays iCloud Keychain). `--sync-gc-settle 2`: the settle delay is two
/// seconds instead of a day. Never the real iCloud, never the real keychain; the notes and pictures are synthetic.
///
/// - `-a`: Mac A pins two notes in Work, "Clean-up plan" and "Keeps", each with a drawn picture, and turns sync on.
/// - `-b`, `-c`: B and C join (Merge) and each edit "Clean-up plan", so every Mac has a text record of it. C then deletes
///   it. Nothing is deleted from iCloud yet: A and B haven't answered.
/// - `-a2`: A hears of the deletion and acks; B still hasn't, so nothing goes (a Mac away holds clean-up back).
/// - `-b2` … `-c3`: each Mac acks, deletes its own text record once every Mac agreed and the settle delay passed; the
///   collector proposes the deleted note's picture, the others answer, and it goes. At the end only C's removal (a
///   tombstone, no text) is left of the deleted note; "Keeps", its picture and the sidebar are untouched everywhere, and
///   nothing in iCloud is readable.
extension SnapshotRunner {
    func iCloudSyncGCScenario() {
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
        let idsFile = shared.appendingPathComponent("gc-notes.txt")
        let firstKeychain = keychain.deletingLastPathComponent().appendingPathComponent("keychain-a", isDirectory: true)
        let database = try? SyncFolderCloudDatabase(folder: mock)
        let fm = FileManager.default
        func say(_ ok: Bool, _ what: String) { check(ok, "\(script) (\(tag)): " + what) }
        func records() -> [SyncCloudRecord] { ((try? database?.withState { $0 })?.records(zone: SyncCloudSchema.zone)) ?? [] }
        func groupKey() -> (UUID, SymmetricKey)? {
            guard let group = records().compactMap(SyncCloudSchema.group).first,
                  let key = try? FolderSyncKeyStore(folder: firstKeychain).key(group: group.group) else { return nil }
            return (group.group, key)
        }
        /// The deleted note's records in iCloud: name → whether it holds text (false: a removal).
        func noteRecords(_ id: String) -> [String: Bool] {
            guard let (group, key) = groupKey() else { return [:] }
            var result: [String: Bool] = [:]
            for r in records() where r.type == SyncCloudSchema.note && r.name.hasSuffix("." + id) {
                result[r.name] = (try? SyncCloudSchema.note(r)?.open(group: group, key: key).removed) == false
            }
            return result
        }
        func pictures() -> Set<String> { Set(records().filter { $0.type == SyncCloudSchema.noteAsset }.map(\.name)) }
        func pictureName(_ file: String?) -> String? { file.flatMap { f in groupKey().map { SyncNoteAsset.name(for: f, key: $0.1) } } }
        func ids() -> [String] { ((try? String(contentsOf: idsFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func row(_ id: String) -> Item? { c.store.state.items.values.first { $0.savedURL == NoteURL.make(id) } }
        func picture(_ color: NSColor) -> NoteImage? {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            guard let rep else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill(); NSRect(x: 0, y: 0, width: 48, height: 32).fill()
            NSColor.white.setFill(); NSRect(x: 6, y: 6, width: 20, height: 14).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:]).flatMap { NoteImages.store($0, ext: "png") }
        }
        func waitFor(_ what: String, timeout: Double = 30, _ condition: @escaping () -> Bool) {
            step { [self] done in
                waitUntil(condition, timeout: timeout) { [self] in
                    if !condition() { note("FAIL \(script) (\(tag)): timed out waiting for \(what) (status \(sync.status))") }
                    done()
                }
            }
        }
        /// One full cycle, awaited.
        func cycle() { step { done in sync.syncNow { done() } } }
        /// Cycles with the settle delay (2 s here) between them: what qualified in one goes in the next.
        func settleCycles(_ n: Int = 3) { for _ in 0..<n { cycle(); wait(2.5) }; cycle() }
        func copyKeys() {
            try? fm.createDirectory(at: keychain, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: firstKeychain, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.copyItem(at: file, to: keychain.appendingPathComponent(file.lastPathComponent))
            }
        }
        func edit(_ id: String, _ text: String) {
            let files = c.store.state.notes[id]?.document.imageFiles.sorted() ?? []
            var blocks = [NoteBlock(runs: [NoteRun(text)])]
            for file in files { blocks.append(NoteBlock(runs: [NoteRun(image: NoteImage(file: file, width: 48, height: 32))])) }
            c.store.updateNote(id, document: NoteDocument(blocks: blocks))
        }
        /// Turn sync on (a second launch has it on already) and wait for a first finished cycle.
        func connect(join: Bool) {
            run { [self] in
                if join { copyKeys() }
                app?.showSettings(page: .sync)
                if !sync.isEnabled { sync.setEnabled(true) }
            }
            if join {
                waitFor("the first-sync screen") { sync.firstSync != nil }
                run { sync.choose(.merge, profiles: [:]) }
            }
            waitFor("up to date") { sync.status == .upToDate }
        }
        /// Nothing of the notes' words in any record (everything is sealed).
        func readable() -> Bool {
            let raw = String(decoding: (try? JSONEncoder().encode(records())) ?? Data(), as: UTF8.self)
            return ["Clean-up plan", "Keeps", "edited on"].contains { raw.contains($0) }
        }

        switch script {
        case "icloudsync-gc-a":
            run { [self] in
                do {
                    let work = try c.store.createSpace(name: "Work", icon: .emoji("💼"))
                    try pin("https://example.com/gc-board", title: "Board", icon: nil, space: work.id)
                    var made: [String] = []
                    for (title, color) in [("Clean-up plan", NSColor.systemTeal), ("Keeps", NSColor.systemOrange)] {
                        let n = try c.store.createNote(inSpace: work.id)
                        let id = NoteURL.noteID(n.url)!
                        var blocks = [NoteBlock(runs: [NoteRun(title)])]
                        if let p = picture(color) { blocks.append(NoteBlock(runs: [NoteRun(image: p)])) }
                        c.store.updateNote(id, document: NoteDocument(blocks: blocks))
                        made.append(id)
                    }
                    try made.joined(separator: "\n").write(to: idsFile, atomically: true, encoding: .utf8)
                    c.switchToSpace(work.id, animated: false)
                } catch { note("FAIL \(script) (\(tag)): seeding: \(error)") }
            }
            connect(join: false)
            cycle()
            run {
                let ids = ids()
                say(ids.count == 2 && pictures().count == 2 && ids.allSatisfy { noteRecords($0).values.allSatisfy { $0 } }
                    && !readable(), "A sent two notes and their pictures, sealed")
            }

        case "icloudsync-gc-b", "icloudsync-gc-c":
            let me = script.hasSuffix("-b") ? "B" : "C"
            connect(join: true)
            run { [self] in
                let id = ids().first ?? ""
                say(row(id) != nil && c.store.note(id) != nil, "\(me) joined and has the notes")
                edit(id, "Clean-up plan, edited on \(me)")
            }
            wait(0.5)
            cycle()
            if me == "C" {
                var before: [String: Bool] = [:]
                var picturesBefore = Set<String>()
                run { [self] in
                    let id = ids().first ?? ""
                    before = noteRecords(id)
                    picturesBefore = pictures()
                    say(before.values.filter { $0 }.count == 3, "each Mac has a text record of the note (\(before.count))")
                    if let r = row(id) { try? c.store.deleteItem(r.id) }
                }
                wait(0.5)
                settleCycles(2)
                run { [self] in
                    let id = ids().first ?? ""
                    let after = noteRecords(id)
                    say(row(id) == nil && after.values.filter { $0 }.count == 2 && pictures() == picturesBefore,
                        "C deleted the note; its record is a removal now, and nothing is deleted while A and B haven't answered")
                }
            }

        case "icloudsync-gc-a2":
            connect(join: false)
            settleCycles(2)
            run { [self] in
                let id = ids().first ?? ""
                let texts = noteRecords(id).values.filter { $0 }.count
                say(row(id) == nil && texts >= 1 && pictures().count == 2,
                    "A heard of the deletion and answered; B hasn't synced since, so its text and the picture stay (\(texts) texts)")
            }

        case "icloudsync-gc-b2", "icloudsync-gc-c2", "icloudsync-gc-a3", "icloudsync-gc-b3":
            connect(join: false)
            settleCycles()
            run { [self] in
                let id = ids().first ?? ""
                let device = MainActor.assumeIsolated { sync.engine?.deviceID } ?? UUID()
                let mine = SyncCloudSchema.noteName(device: device, note: id)
                say(noteRecords(id)[mine] != true && sync.status == .upToDate,
                    "every Mac agreed: this Mac's own text record of the deleted note is gone (\(noteRecords(id).count) records left)")
            }

        case "icloudsync-gc-c3":
            connect(join: false)
            settleCycles()
            run { [self] in
                let ids = ids()
                let gone = ids.first ?? "", kept = ids.last ?? ""
                let left = noteRecords(gone)
                say(left.count == 1 && left.values.first == false,
                    "only the deleted note's removal is left (a tombstone, no text): \(left.count) record(s)")
                let keptFile = c.store.note(kept)?.document.imageFiles.first
                say(pictures() == Set([pictureName(keptFile)].compactMap { $0 }),
                    "its picture went, and the other note's stayed (\(pictures().count) picture(s))")
                say(c.store.note(kept)?.document.plainText.hasPrefix("Keeps") == true && row(kept) != nil
                    && c.store.state.items.values.contains { $0.savedURL == "https://example.com/gc-board" },
                    "the other note, its row and the sidebar are as they were")
                let unreadable = MainActor.assumeIsolated { sync.engine?.unreadableBatches }
                say(!readable() && sync.status == .upToDate && unreadable == 0, "nothing readable in iCloud; up to date")
            }

        default:
            note("FAIL unknown clean-up script \(script)")
        }
    }
}
#endif
