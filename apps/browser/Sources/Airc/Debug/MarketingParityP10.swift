// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircKit
import AppKit

/// P10a's shots, `--script marketing` part `parityp10`:
///   - library-folders: Library › Media showing a "Desktop" folder the person allowed, beside a Capture: synthetic
///     illustrations (MarketingLibrary's) in a folder made in the run's own data folder; the panel is answered here, so
///     no real folder is read;
///   - library-notes: Library › Notes, every note in one list (synthetic notes in two Spaces, one in a closed folder).
extension SnapshotRunner {
    func mkParityP10Shots(_ d: MarketingDemo) {
        let fm = FileManager.default
        let folder = AppPaths.dataDirectory.appendingPathComponent("MarketingDesktop", isDirectory: true)
        let sources = LibraryFolderSources.shared
        step { done in DispatchQueue.global(qos: .userInitiated).async { _ = Self.mkLibraryMedia; DispatchQueue.main.async(execute: done) } }
        run { [self] in
            try? fm.removeItem(at: folder)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let names = ["Coast at dusk.jpg", "Studio moodboard.png", "Desert road.jpg", "Brand palette.png", "Alfama rooftops.jpg", "Launch teaser.mov"]
            for (i, name) in names.enumerated() {
                guard let f = Self.mkLibraryMedia[name] else { continue }
                let url = folder.appendingPathComponent(name)
                try? f.data.write(to: url)
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(i) * 3600 * 5)], ofItemAtPath: url.path)
            }
            LibraryFolderSources.testDefaultURL = { _ in folder }
            LibraryFolderSources.testPanel = { _, url in url }
            if let sid = d.space["work"] { c.switchToSpace(sid, animated: false) }
            if c.library == nil { c.toggleLibrary() }
            c.library?.model.section = .media
            sources.start()
            sources.requestAccess(.desktop, for: c.window)
        }
        // The page beside the Library is drawn before the picture.
        mkSettleShown(timeout: 8, extra: 0.6)
        step { done in self.waitUntil({ sources.files.count >= 5 }, timeout: 6) { done() } }
        step { done in LibraryFiles.shared.refresh(done) }
        step { [self] done in
            waitUntil({ LibraryFiles.shared.media.allSatisfy { LibraryThumbnails.shared.pictured.contains($0.path) } }, timeout: 10) {
                self.note("marketing: library-folders: \(LibraryFiles.shared.media.count) tiles")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
            }
        }
        step { [self] done in mkWindowShotNow("library-folders", dark: mkIsDark(), done) }

        // Notes in two Spaces, one in a closed folder: all in one list.
        run { [self] in
            let store = c.store
            guard let work = d.space["work"], let personal = d.space["personal"] else { return note("marketing: MISSING library-notes: no Spaces") }
            let docs: [(String, [String], String, Bool)] = [
                (work, ["Q3 launch checklist", "Press kit, landing page, changelog", "Book the demo room"], work, false),
                (personal, ["Lisbon packing list", "Adapters, sunscreen, the good camera"], personal, true),
                (personal, ["Pastéis de nata", "Puff pastry, six yolks, a hot oven"], personal, false),
                (work, ["Interview notes", "Ask about on-call and the design review"], work, true),
            ]
            for (space, lines, _, inFolder) in docs {
                var parent: String?
                if inFolder {
                    parent = store.children(of: .pinned(spaceID: space), parent: nil).first { $0.kind == .folder && $0.title == "Notes" }?.id
                        ?? (try? store.createFolder(named: "Notes", inSpace: space))?.id
                }
                _ = try? store.createNote(inSpace: space, parentID: parent, document: NoteDocument(lines: lines))
            }
            for f in store.state.items.values where f.kind == .folder && f.title == "Notes" && !f.isCollapsed { try? store.toggleFolder(f.id) }
            c.library?.model.section = .notes
        }
        wait(0.8)
        step { [self] done in mkWindowShotNow("library-notes", dark: mkIsDark(), done) }
        run { [self] in
            sources.forget(.desktop)
            LibraryFolderSources.testPanel = nil
            LibraryFolderSources.testDefaultURL = nil
            if c.library != nil { c.toggleLibrary() }
            try? fm.removeItem(at: folder)
        }
        wait(0.5)
    }
}
#endif
