// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script parityp10`, then `parityp10-relaunch` in a fresh process on the same data dir (both engines): the Library
/// as a home (P10a). Only scratch folders in the run's data folder stand in for Desktop, Documents, Downloads and
/// Screenshots (`LibraryFolderSources.testDefaultURL`), and the open panel is answered by `testPanel`: the owner's own
/// folders are never read, and no privacy prompt can come up.
///   - folder sources: not granted, then declined (Cancel), then granted; a folder's top-level pictures and videos show
///     (not its text files, hidden files or the folders inside it); a file added, renamed or deleted shows within a
///     second or two, read off the main thread; a granted folder deleted is "revoked" until chosen again; a folder
///     turned off and on; "Hide from Library"; Captures and Downloads switched off and on;
///   - private files: a private window's download and a private Capture never show, even in a shown folder;
///   - Notes: every note listed newest first, searchable, and opened wherever its row is (a closed folder in another
///     Space, the Archive, nowhere);
///   - Archived Tabs' filters: a Space, Little Arc, auto- and manually closed;
///   - after a relaunch: the grants, the hidden file and the declined folder are kept, and the folder shows again.
extension SnapshotRunner {
    func parityP10Scenario() {
        if script == "parityp10-relaunch" { return parityP10Relaunch() }
        let store = c.store
        let fm = FileManager.default
        let root = AppPaths.dataDirectory.appendingPathComponent("P10Folders", isDirectory: true)
        func folder(_ f: LibraryFolder) -> URL { root.appendingPathComponent(f.rawValue.capitalized, isDirectory: true) }
        let sources = LibraryFolderSources.shared
        var answer: [LibraryFolder: URL?] = [:]
        func names() -> [String] { sources.files.map(\.name) }
        func media() -> [String] { LibraryFiles.shared.media.map(\.name) }

        run { [self] in
            try? fm.removeItem(at: root)
            for f in LibraryFolder.allCases { try? fm.createDirectory(at: folder(f), withIntermediateDirectories: true) }
            let d = folder(.desktop)
            Self.p10Write(d.appendingPathComponent("beach.png"), minutesAgo: 30)
            Self.p10Write(d.appendingPathComponent("plan.jpg"), minutesAgo: 10)
            Self.p10Write(d.appendingPathComponent("clip.mov"), minutesAgo: 20, png: false)
            try? Data("words".utf8).write(to: d.appendingPathComponent("notes.txt"))
            try? fm.createDirectory(at: d.appendingPathComponent("Inside"), withIntermediateDirectories: true)
            Self.p10Write(d.appendingPathComponent("Inside/deep.png"), minutesAgo: 5)
            Self.p10Write(d.appendingPathComponent(".dotfile.png"), minutesAgo: 1)
            Self.p10Write(folder(.documents).appendingPathComponent("scan.png"), minutesAgo: 40)
            LibraryFolderSources.testDefaultURL = { folder($0) }
            LibraryFolderSources.testPanel = { f, suggested in answer[f] ?? suggested }
            sources.resetForTesting()
            var s = sources.settings
            s = LibrarySourceSettings()
            sources.settings = s
            c.toggleLibrary()
            c.library?.model.section = .media
        }
        wait(0.6)
        run { [self] in
            check(sources.states[.desktop] == .notGranted && sources.files.isEmpty,
                  "parityp10 sources: nothing is read before the person allows a folder (\(String(describing: sources.states[.desktop])))")
            answer[.desktop] = .some(nil)
            sources.requestAccess(.desktop, for: c.window)
            check(sources.states[.desktop] == .declined && sources.settings.declined.contains("desktop") && sources.files.isEmpty,
                  "parityp10 sources: Cancel in the panel is a no, remembered, and nothing is read")
            answer[.desktop] = nil
            sources.requestAccess(.desktop, for: c.window)
        }
        step { [self] done in waitUntil({ !sources.files.isEmpty }, timeout: 3) { done() } }
        run { [self] in
            check(sources.states[.desktop] == .granted(path: folder(.desktop).path) && sources.settings.grant(.desktop) != nil,
                  "parityp10 sources: Allow keeps a bookmark of the folder picked")
            check(names() == ["plan.jpg", "clip.mov", "beach.png"],
                  "parityp10 sources: the folder's pictures and videos at its top, newest first; no text file, dot file or inner folder (\(names()))")
            check(sources.files.allSatisfy { $0.source == .folder }, "parityp10 sources: listed as folder files")
            Self.p10Write(folder(.desktop).appendingPathComponent("new.png"), minutesAgo: 0)
        }
        step { [self] done in waitUntil({ names().first == "new.png" }, timeout: 3) { done() } }
        run { [self] in
            check(names().first == "new.png", "parityp10 watch: a file saved to the folder shows (\(names()))")
            try? fm.moveItem(at: folder(.desktop).appendingPathComponent("beach.png"), to: folder(.desktop).appendingPathComponent("dunes.png"))
            try? fm.removeItem(at: folder(.desktop).appendingPathComponent("clip.mov"))
        }
        step { [self] done in waitUntil({ !names().contains("clip.mov") && names().contains("dunes.png") }, timeout: 3) { done() } }
        run { [self] in
            check(names() == ["new.png", "plan.jpg", "dunes.png"], "parityp10 watch: a rename and a deletion in Finder show (\(names()))")
            check(sources.mainThreadReads == 0, "parityp10 watch: no folder was read on the main thread")
        }
        // Media merges them with Airc's own Captures (and downloads), each source switchable.
        run { [self] in
            let shot = AppPaths.dataDirectory.appendingPathComponent("P10Capture.png")
            Self.p10Write(shot, minutesAgo: 2)
            LibraryFiles.shared.recordCapture(shot, isPrivate: false)
        }
        step { [self] done in waitUntil({ media().contains("P10Capture.png") && media().contains("new.png") }, timeout: 3) { done() } }
        run { [self] in
            check(media().contains("P10Capture.png") && media().contains("new.png"), "parityp10 media: Captures and the folder in one grid (\(media()))")
            var s = sources.settings
            s.showCaptures = false
            sources.settings = s
            LibraryFiles.shared.refresh()
        }
        step { [self] done in waitUntil({ !media().contains("P10Capture.png") }, timeout: 2) { done() } }
        run { [self] in
            check(!media().contains("P10Capture.png") && media().contains("new.png"), "parityp10 media: Captures switched off (\(media()))")
            var s = sources.settings
            s.showCaptures = true
            sources.settings = s
            sources.setShown(.desktop, false)
        }
        step { [self] done in waitUntil({ !media().contains("new.png") && media().contains("P10Capture.png") }, timeout: 2) { done() } }
        run { [self] in
            check(!media().contains("new.png") && media().contains("P10Capture.png") && sources.settings.grant(.desktop) != nil,
                  "parityp10 media: the folder switched off keeps its grant (\(media()))")
            sources.setShown(.desktop, true)
        }
        step { [self] done in waitUntil({ media().contains("new.png") }, timeout: 3) { done() } }

        // Private files: a private window's download and Capture never show, also in a shown folder.
        run { [self] in
            let d = folder(.desktop)
            LibraryFiles.shared.notePrivatePath(d.appendingPathComponent("private-download.png").path)
            Self.p10Write(d.appendingPathComponent("private-download.png"), minutesAgo: 0)
            let privCapture = d.appendingPathComponent("private-capture.png")
            Self.p10Write(privCapture, minutesAgo: 0)
            LibraryFiles.shared.recordCapture(privCapture, isPrivate: true)
            Self.p10Write(d.appendingPathComponent("after.png"), minutesAgo: 0)
        }
        step { [self] done in waitUntil({ names().contains("after.png") }, timeout: 3) { done() } }
        run { [self] in
            check(!names().contains("private-download.png") && !names().contains("private-capture.png") && !media().contains("private-capture.png"),
                  "parityp10 private: a private window's download and Capture don't show, though they're in the folder (\(names()))")
            check(!((try? String(contentsOf: AppPaths.dataDirectory.appendingPathComponent("settings.json"), encoding: .utf8)) ?? "").contains("private-"),
                  "parityp10 private: their paths aren't written anywhere (settings.json)")
            // Hide from Library.
            if let f = sources.files.first(where: { $0.name == "plan.jpg" }) { sources.hide(f) }
        }
        step { [self] done in waitUntil({ !media().contains("plan.jpg") }, timeout: 2) { done() } }
        run { [self] in
            check(!names().contains("plan.jpg") && fm.fileExists(atPath: folder(.desktop).appendingPathComponent("plan.jpg").path)
                  && sources.settings.hidden.contains(folder(.desktop).appendingPathComponent("plan.jpg").path),
                  "parityp10 hide: Hide from Library takes it off the grid and leaves the file")
            // A second folder, then taken away: revoked until chosen again.
            sources.requestAccess(.documents, for: c.window)
        }
        step { [self] done in waitUntil({ names().contains("scan.png") }, timeout: 3) { done() } }
        run { [self] in
            check(names().contains("scan.png"), "parityp10 sources: a second folder adds its files (\(names()))")
            try? fm.removeItem(at: folder(.documents))
        }
        step { [self] done in waitUntil({ if case .revoked = sources.states[.documents] { return true }; return false }, timeout: 3) { done() } }
        run { [self] in
            var revoked = false
            if case .revoked = sources.states[.documents] { revoked = true }
            check(revoked && !names().contains("scan.png"), "parityp10 sources: a granted folder that's gone is revoked and its files go (\(String(describing: sources.states[.documents])))")
            try? fm.createDirectory(at: folder(.documents), withIntermediateDirectories: true)
            Self.p10Write(folder(.documents).appendingPathComponent("again.png"), minutesAgo: 0)
            sources.requestAccess(.documents, for: c.window)
        }
        step { [self] done in waitUntil({ names().contains("again.png") }, timeout: 3) { done() } }
        run { [self] in
            check(sources.states[.documents]?.isGranted == true && names().contains("again.png"), "parityp10 sources: Choose Again grants it anew")
        }
        // A picture of the Library's Media with a folder (the report's and the marketing shot's look).
        run { [self] in p10Shot("parityp10-media") }

        // Notes, wherever they are.
        var noteIDs: [String: String] = [:]
        run { [self] in
            do {
                let home = c.currentSpaceID
                let other = try store.createSpace(name: "Writing", profileID: store.profile(ofSpace: home).id, after: home)
                let folder = try store.createFolder(named: "Drafts", inSpace: other.id)
                let deep = try store.createNote(inSpace: other.id, parentID: folder.id,
                                                document: NoteDocument(lines: ["Zebra crossing", "where the zebras cross"]))
                noteIDs["deep"] = store.note(forTab: deep.id)?.id
                try store.toggleFolder(folder.id)
                let today = try store.createNote(inSpace: home, pinned: false, document: NoteDocument(lines: ["Shopping", "milk, eggs"]))
                noteIDs["archived"] = store.note(forTab: today.id)?.id
                _ = try store.closeTab(today.id)
                c.switchToSpace(home, animated: false)
                c.library?.model.section = .notes
            } catch { check(false, "parityp10 notes: the notes for the check (\(error))") }
        }
        wait(0.4)
        run { [self] in
            let all = LibraryNotes.entries(store)
            check(all.count >= 2 && all.contains { $0.note.id == noteIDs["deep"] } && all.contains { $0.note.id == noteIDs["archived"] },
                  "parityp10 notes: every note is listed, in a closed folder of another Space and archived (\(all.map(\.note.displayTitle)))")
            check(LibraryNotes.entries(store, query: "zebras").map(\.note.id) == [noteIDs["deep"]].compactMap { $0 },
                  "parityp10 notes: the search finds a note by its text")
            if case .archived = all.first(where: { $0.note.id == noteIDs["archived"] })?.place {} else {
                check(false, "parityp10 notes: the closed note is in the Archive")
            }
            guard let n = store.note(noteIDs["deep"]) else { return check(false, "parityp10 notes: the deep note") }
            check(LibraryNotes.open(n, in: c), "parityp10 notes: opening the deep note")
        }
        wait(0.4)
        run { [self] in
            let shown = store.note(forTab: c.shownTabID)?.id
            let space = store.space(c.currentSpaceID)?.name
            let folderOpen = store.state.items.values.first { $0.kind == .folder && $0.title == "Drafts" }?.isCollapsed == false
            check(shown == noteIDs["deep"] && space == "Writing" && folderOpen,
                  "parityp10 notes: it opens in its Space with its folder opened (\(space ?? "-"), folder open \(folderOpen))")
            guard let n = store.note(noteIDs["archived"]) else { return check(false, "parityp10 notes: the archived note") }
            check(LibraryNotes.open(n, in: c), "parityp10 notes: opening the archived note")
        }
        wait(0.3)
        run { [self] in
            check(store.note(forTab: c.shownTabID)?.id == noteIDs["archived"] && !store.state.archive.values.contains { $0.tab.url == NoteURL.make(noteIDs["archived"] ?? "") },
                  "parityp10 notes: the archived note comes back from the Archive and shows")
        }

        // Archived Tabs' filters, with a real Little Arc page archived the way its six hours end (LittleArc.archiveNow).
        var little: LittleArcController?
        run { [self] in
            do {
                let home = c.currentSpaceID
                let a = try store.openTab(url: "https://manual.example", inSpace: home, title: "Manual")
                let b = try store.openTab(url: "https://auto.example", inSpace: home, title: "Auto")
                _ = try store.closeTab(a.id)
                _ = try store.archiveTabs([b.id], reason: .auto, label: "Archive")
                little = c.app?.openLittleArc(url: URL(string: "data:text/html,<title>From%20Little%20Arc</title>small"), spaceID: home)
                c.library?.model.section = .archive
            } catch { check(false, "parityp10 archive: the entries (\(error))") }
        }
        step { [self] done in waitUntil({ little?.page?.url != nil && little?.page?.isLoading == false }, timeout: 6) { done() } }
        run { little?.archiveNow() }
        step { [self] done in
            waitUntil({ store.state.archive.values.contains { $0.origin == ArchiveEntry.littleArcOrigin } }, timeout: 4) { done() }
        }
        run { [self] in
            guard let m = c.library?.model else { return check(false, "parityp10 archive: the Library") }
            let littleTitle = store.state.archive.values.first { $0.origin == ArchiveEntry.littleArcOrigin }?.title ?? "none"
            check(littleTitle != "none", "parityp10 archive: Little Arc's archived page is marked as Little Arc's (\(littleTitle))")
            func titles() -> Set<String> {
                Set(m.days.flatMap(\.entries).map { $0.origin == ArchiveEntry.littleArcOrigin ? "From Little Arc" : $0.title })
                    .intersection(["Manual", "Auto", "From Little Arc"])
            }
            check(titles() == ["Manual", "Auto", "From Little Arc"], "parityp10 archive: unfiltered, all three (\(titles()))")
            m.archiveFilter = ArchiveFilter(place: .littleArc)
            check(titles() == ["From Little Arc"], "parityp10 archive: Little Arc (\(titles()))")
            m.archiveFilter = ArchiveFilter(place: .space(c.currentSpaceID))
            check(titles() == ["Manual", "Auto"], "parityp10 archive: the Space, without Little Arc's page (\(titles()))")
            m.archiveFilter = ArchiveFilter(closing: .automatic)
            check(titles() == ["Auto", "From Little Arc"], "parityp10 archive: Auto-Closed (\(titles()))")
            m.archiveFilter = ArchiveFilter(closing: .manual)
            check(titles() == ["Manual"], "parityp10 archive: Manually Closed (\(titles()))")
            p10Shot("parityp10-archive-filter")
            m.archiveFilter = ArchiveFilter()
            c.library?.model.section = .notes
        }
        wait(0.3)
        run { [self] in
            p10Shot("parityp10-notes")
            c.library?.model.section = .media
            LibraryFolderSources.testPanel = nil
        }
    }

    /// The second process: the grants, the hidden file and the declined folder are read back, and the folder shows again
    /// from its bookmark.
    private func parityP10Relaunch() {
        let root = AppPaths.dataDirectory.appendingPathComponent("P10Folders", isDirectory: true)
        let sources = LibraryFolderSources.shared
        run { [self] in
            LibraryFolderSources.testDefaultURL = { root.appendingPathComponent($0.rawValue.capitalized, isDirectory: true) }
            let s = sources.settings
            check(s.grant(.desktop) != nil && s.grant(.documents) != nil, "parityp10-relaunch: both grants were kept")
            check(s.hidden.contains(root.appendingPathComponent("Desktop/plan.jpg").path), "parityp10-relaunch: the hidden file stays hidden")
            c.toggleLibrary()
            c.library?.model.section = .media
        }
        step { [self] done in waitUntil({ sources.files.contains { $0.name == "new.png" } }, timeout: 4) { done() } }
        run { [self] in
            let names = sources.files.map(\.name)
            check(names.contains("new.png") && names.contains("again.png") && !names.contains("plan.jpg"),
                  "parityp10-relaunch: the folders show again from their bookmarks (\(names))")
        }
    }

    /// A small picture (or, `png: false`, any bytes with a video's name) dated `minutesAgo`.
    static func p10Write(_ url: URL, minutesAgo: Double, png: Bool = true) {
        let data: Data
        if png {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            data = rep.representation(using: .png, properties: [:]) ?? Data([1])
        } else {
            data = Data(repeating: 7, count: 64)
        }
        try? data.write(to: url)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: url.path)
    }

    func p10Shot(_ name: String) {
        guard let v = c.library, let img = render(v) else { return note("parityp10: no picture of \(name)") }
        try? img.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])?
            .write(to: dir.appendingPathComponent(name + ".png"))
        note("wrote \(name).png")
    }
}
#endif
