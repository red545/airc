// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    func clearArchiveCheck() {
        var count = 0
        var originalFolder: String?
        let model = { self.c.library?.model }
        run { [self] in
            originalFolder = app?.settings.values.backupFolder
            app?.settings.values.backupFolder = dir.appendingPathComponent("clear-backups").path
            do {
                let p = try c.store.createProfile(name: "Archive check", emoji: "🌱")
                let s = try c.store.createSpace(name: "Archive elsewhere", profileID: p.id)
                for sid in [c.currentSpaceID, s.id] {
                    let t = try c.store.openTab(url: "https://example.com/archive", inSpace: sid, activate: false, title: "Archived example")
                    _ = try c.store.closeTab(t.id)
                }
            } catch { check(false, "clear archive: fixture: \(error)") }
            if c.library == nil { c.toggleLibrary() }
            model()?.section = .archive
            count = c.store.state.archive.count
        }
        wait(0.6)
        capture("archive-before")
        clickIn({ self.c.library }, "library.clearArchive")
        wait(0.3)
        run { [self] in
            if model()?.archiveConfirmation == nil {
                check(TestAnchors.frames["library.clearArchive"] != nil, "clear archive: button is rendered")
                note("clear archive: background SwiftUI click did not open the sheet; invoking the button's own model action")
                model()?.requestClearArchive()
            }
        }
        wait(0.3)
        run { [self] in
            let alert = model()?.archiveConfirmation
            check(alert != nil && c.window.attachedSheet === alert?.window, "clear archive: confirmation is attached")
            check(alert?.messageText == "Are you sure you'd like to Clear Archive?"
                  && alert?.informativeText.contains("every Space and profile") == true
                  && alert?.informativeText.contains("undo this right after") == true
                  && alert?.informativeText.contains("backup") == true
                  && (alert?.accessoryView?.subviews.compactMap { $0 as? NSButton }.first?.title ?? "") == "Everything (\(count) tabs)",
                  "clear archive: Arc's question, with global scope, the one Undo, the recovery backup and the count for Everything")
            if let view = alert?.window.contentView, let image = render(view),
               let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data) {
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("archive-confirmation.png"))
            }
            note("clear archive: driving native sheet buttons with performClick, without taking focus")
            alert?.buttons[0].performClick(nil)
        }
        wait(0.4)
        run { [self] in
            check(c.store.state.archive.count == count && model()?.lastArchiveBackup == nil,
                  "clear archive: Cancel leaves archive and backups unchanged")
            model()?.query = "no matching archived title"
            model()?.requestClearArchive()
        }
        wait(0.3)
        run { model()?.archiveConfirmation?.buttons[1].performClick(nil) }
        wait(0.5)
        run { [self] in
            check(c.store.state.archive.isEmpty, "clear archive: confirmed removal empties all profiles, including search-hidden entries")
            do {
                let url = model()?.lastArchiveBackup
                check(url != nil && FileManager.default.fileExists(atPath: url!.path), "clear archive: recovery backup exists")
                if let url {
                    let recovered = try SpacesStore(path: nil)
                    try recovered.restore(fromBackup: Data(contentsOf: url))
                    check(recovered.state.archive.count == count, "clear archive: backup restores every removed entry")
                }
                _ = try c.store.undo()
                check(c.store.state.archive.isEmpty, "clear archive: ⌘Z cannot restore removed entries (only the toast's Undo)")
                check(model()?.pendingUndo?.count == count, "clear archive: the toast's Undo holds what was cleared")
                model()?.undoClear()
                check(c.store.state.archive.count == count, "clear archive: the toast's Undo puts every entry back")
                model()?.undoClear()
                check(c.store.state.archive.count == count, "clear archive: Undo works once (nothing doubled)")
                _ = try c.store.clearArchive(age: .everything) {}
            } catch { check(false, "clear archive: recovery: \(error)") }
            model()?.query = ""
            app?.settings.values.backupFolder = originalFolder
        }
        capture("archive-empty")
    }
}
#endif
