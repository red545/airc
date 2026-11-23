// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script paritybackupfolder` (SET-3, both engines; paritysweep): a backup folder chosen in Settings › General ›
/// Back up to is used by the archive-triggered backup, and the launch sweep of note pictures reads it:
///   1. auto-archive (the store's clock 40 days on, then the archive timer's action) archives the due tabs and writes
///      that day's backup into the chosen folder, not the default one;
///   2. `backupFolders` names the chosen folder and the default;
///   3. the sweep keeps a picture that only a backup in the chosen folder names, and a picture that only a backup in
///      the default folder names (older backups stay there after a change). It removes a picture no backup names.
///      Before the fix, the sweep read only the default folder and removed the first one, so restoring that backup
///      showed "Picture not on this Mac";
///   4. with the chosen folder gone (a drive not plugged in), the sweep removes nothing.
/// No real input: nothing here is pointer- or key-driven. Zero-guard: the run fails if it made too few assertions.
extension SnapshotRunner {
    @MainActor func parityBackupFolderScenario() {
        let tag = "paritybackupfolder (\(app?.engine is WebKitEngine ? "WebKit" : "Chromium"))"
        var asserted = 0
        func expect(_ ok: Bool, _ what: String) { asserted += 1; check(ok, "\(tag): \(what)") }
        let fm = FileManager.default
        let chosen = dir.appendingPathComponent("chosen-backups", isDirectory: true)
        let gone = dir.appendingPathComponent("unplugged-drive/Backups", isDirectory: true)
        var original: String?
        var ids: [String] = []
        let day: (Date) -> String = { d in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return "airc-backup-\(f.string(from: d)).json"
        }
        // Valid note picture names (NoteImage.isValidFile): hex plus an image extension.
        let inChosen = String(repeating: "a1", count: 32) + ".png"
        let inDefault = String(repeating: "b2", count: 32) + ".png"
        let unnamed = String(repeating: "c3", count: 32) + ".png"
        let pictures = NoteImages.folder
        func put(_ name: String) { try? Data([0x89, 0x50, 0x4e, 0x47]).write(to: pictures.appendingPathComponent(name)) }
        func has(_ name: String) -> Bool { fm.fileExists(atPath: pictures.appendingPathComponent(name).path) }

        run { [self] in
            guard let settings = app?.settings else { return expect(false, "fixture: the app's settings") }
            original = settings.values.backupFolder
            try? fm.removeItem(at: chosen)
            settings.values.backupFolder = chosen.path
            do {
                for i in 0..<3 {
                    let t = try c.store.openTab(url: "https://example.com/backup-folder-\(i)", inSpace: c.currentSpaceID,
                                                activate: false, title: "Backup folder \(i)")
                    ids.append(t.id)
                }
            } catch { expect(false, "fixture: tabs: \(error)") }
            // 1. The archive timer's action, 40 days on.
            let later = Date().addingTimeInterval(40 * 86400)
            let defaultBefore = Set((try? fm.contentsOfDirectory(atPath: AppPaths.backups.path)) ?? [])
            c.store.now = { later }
            c.runAutoArchive()
            let archived = ids.filter { id in c.store.state.archive.values.contains { $0.tab.id == id && $0.reason == .auto } }
            expect(archived.count == ids.count, "1. auto-archive archived the due tabs (\(archived.count)/\(ids.count))")
            let name = day(later)
            expect(fm.fileExists(atPath: chosen.appendingPathComponent(name).path),
                   "1. the archive-triggered backup \(name) is in the chosen folder")
            let defaultAfter = Set((try? fm.contentsOfDirectory(atPath: AppPaths.backups.path)) ?? [])
            expect(!defaultAfter.contains(name) && defaultAfter.subtracting(defaultBefore).isEmpty,
                   "1. nothing new in the default folder (\(defaultAfter.subtracting(defaultBefore).sorted()))")
            c.store.now = Date.init
            c.scheduleArchive()

            // 2. The folders the sweep reads.
            try? fm.createDirectory(at: AppPaths.backups, withIntermediateDirectories: true)
            let folders = settings.backupFolders.map(\.standardizedFileURL.path)
            expect(folders.contains(chosen.standardizedFileURL.path) && folders.contains(AppPaths.backups.standardizedFileURL.path),
                   "2. backupFolders names the chosen folder and the default (\(folders.count))")

            // 3. The sweep.
            try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)
            for p in [inChosen, inDefault, unnamed] { put(p) }
            let keep = c.store.noteImageFiles
            expect(![inChosen, inDefault, unnamed].contains(where: keep.contains), "3. fixture: no note shows the three pictures")
            let fakeChosen = chosen.appendingPathComponent("airc-backup-manual-paritysweep.json")
            let fakeDefault = AppPaths.backups.appendingPathComponent("airc-backup-manual-paritysweep.json")
            try? Data(#"{"note":"\#(inChosen)"}"#.utf8).write(to: fakeChosen)
            try? Data(#"{"note":"\#(inDefault)"}"#.utf8).write(to: fakeDefault)
            let removed = NoteImages.removeUnused(in: pictures, keeping: keep, backups: settings.backupFolders)
            expect(has(inChosen), "3. a picture only a backup in the chosen folder names is kept")
            expect(has(inDefault), "3. a picture only a backup in the default folder names is kept")
            expect(!has(unnamed) && removed?.contains(unnamed) == true, "3. a picture no backup names is removed (\(removed ?? []))")

            // 4. The chosen folder isn't there.
            put(unnamed)
            settings.values.backupFolder = gone.path
            let none = NoteImages.removeUnused(in: pictures, keeping: keep, backups: settings.backupFolders)
            expect(none == nil && has(unnamed) && has(inChosen) && has(inDefault),
                   "4. with the chosen folder gone, nothing is removed (\(none.map { "\($0)" } ?? "nil"))")

            // Clean up what this check made.
            for p in [inChosen, inDefault, unnamed] { try? fm.removeItem(at: pictures.appendingPathComponent(p)) }
            try? fm.removeItem(at: fakeDefault)
            settings.values.backupFolder = original
            expect(asserted >= 9, "zero-guard: \(asserted + 1) assertions made (10 expected)")
        }
    }
}
#endif
