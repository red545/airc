// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// Notes (Notes.swift): the document model, the rows that carry a note, the schema 2 migration and backups.
final class NotesTests: XCTestCase {
    private func doc(_ blocks: [NoteBlock]) -> NoteDocument { NoteDocument(blocks: blocks) }

    // MARK: The document

    func testTitleIsTheFirstLineWithText() {
        XCTAssertEqual(NoteDocument().title, "")
        XCTAssertEqual(NoteDocument(lines: ["", "  ", "  Groceries  ", "milk"]).title, "Groceries")
        let image = NoteRun(image: NoteImage(file: String(repeating: "a", count: 64) + ".png", width: 10, height: 10))
        XCTAssertEqual(doc([NoteBlock(runs: [image]), NoteBlock(kind: .heading1, runs: [NoteRun("Trip"), NoteRun(" plan", marks: [.bold])])]).title,
                       "Trip plan", "a picture-only line isn't the title; runs join")
        let long = String(repeating: "x", count: 300)
        XCTAssertEqual(NoteDocument(lines: [long]).title.count, NoteDocument.maxTitleLength + 1)
        XCTAssertEqual(Note(document: NoteDocument()).displayTitle, "New Note")
    }

    func testEmptyMeansNoTextAndNoPicture() {
        XCTAssertTrue(NoteDocument().isEmpty)
        XCTAssertTrue(NoteDocument(lines: ["", " \n "]).isEmpty)
        XCTAssertTrue(doc([NoteBlock(kind: .checkbox, runs: [])]).isEmpty, "an empty checkbox is still nothing")
        XCTAssertFalse(NoteDocument(lines: ["a"]).isEmpty)
        let image = NoteRun(image: NoteImage(file: String(repeating: "b", count: 64) + ".png", width: 4, height: 3))
        XCTAssertFalse(doc([NoteBlock(runs: [image])]).isEmpty)
        XCTAssertEqual(doc([NoteBlock(runs: [image, NoteRun("x")])]).imageFiles, [String(repeating: "b", count: 64) + ".png"])
    }

    func testCompactJSONRoundTripsAndNewerValuesReadAsTheNearest() throws {
        let d = doc([
            NoteBlock(kind: .heading2, runs: [NoteRun("Plan")]),
            NoteBlock(kind: .checkbox, indent: 1, checked: true, runs: [NoteRun("book", marks: [.bold, .italic], link: "https://example.com/")]),
            NoteBlock(kind: .numbered, runs: [NoteRun("one", marks: [.code, .strikethrough, .underline])]),
            NoteBlock(runs: [NoteRun("plain")]),
        ])
        let data = try JSONEncoder().encode(d)
        XCTAssertEqual(try JSONDecoder().decode(NoteDocument.self, from: data), d)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#"{"runs":[{"text":"plain"}]}"#), "a plain line writes only its text: \(json)")
        XCTAssertFalse(json.contains("\"indent\":0") || json.contains("\"checked\":false"))

        // A newer build's line kind, mark and field.
        let future = #"{"blocks":[{"kind":"callout","runs":[{"text":"hi","marks":["bold","glow"],"color":"red"}]},{"kind":"bullet","indent":99,"runs":[]}]}"#
        let read = try JSONDecoder().decode(NoteDocument.self, from: Data(future.utf8))
        XCTAssertEqual(read.blocks[0].kind, .paragraph)
        XCTAssertEqual(read.blocks[0].runs[0].marks, [.bold])
        XCTAssertEqual(read.blocks[1].indent, NoteBlock.maxIndent)
        // Indents and ticks only exist where they mean something.
        XCTAssertEqual(NoteBlock(kind: .paragraph, indent: 3, checked: true).indent, 0)
        XCTAssertFalse(NoteBlock(kind: .bullet, checked: true).checked)
    }

    func testMarkdown() {
        let d = doc([
            NoteBlock(kind: .heading1, runs: [NoteRun("Title")]),
            NoteBlock(kind: .bullet, runs: [NoteRun("a")]),
            NoteBlock(kind: .bullet, indent: 1, runs: [NoteRun("b", marks: [.bold])]),
            NoteBlock(kind: .numbered, runs: [NoteRun("one")]),
            NoteBlock(kind: .numbered, indent: 1, runs: [NoteRun("inner")]),
            NoteBlock(kind: .numbered, runs: [NoteRun("two")]),
            NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("done")]),
            NoteBlock(runs: [NoteRun("link", link: "https://example.com/")]),
        ])
        XCTAssertEqual(d.markdown, """
            # Title
            - a
                - **b**
            1. one
                1. inner
            2. two
            - [x] done
            [link](https://example.com/)
            """)
    }

    func testAddresses() {
        XCTAssertEqual(NoteURL.noteID("airc-note:abc"), "abc")
        XCTAssertNil(NoteURL.noteID("airc-note:"))
        XCTAssertNil(NoteURL.noteID("airc-note:a/../b"))
        XCTAssertNil(NoteURL.noteID("https://airc-note.example/"))
        XCTAssertEqual(URLRules.displayHost("airc-note:abc"), "Note")
        XCTAssertTrue(NoteImage.isValidFile(String(repeating: "0", count: 64) + ".png"))
        for bad in ["../x.png", "a.png", String(repeating: "0", count: 64) + ".exe", String(repeating: "0", count: 64) + ".png/.."] {
            XCTAssertFalse(NoteImage.isValidFile(bad), bad)
        }
    }

    // MARK: Rows

    func testNewNoteIsPinnedAtTheBottomAndItsTitleFollowsTheText() throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let pinned = try s.openTab(url: "https://example.com/", inSpace: space)
        try s.togglePin(pinned.id, inSpace: space)
        let t = try s.createNote(inSpace: space)
        let item = try XCTUnwrap(s.item(t.itemID))
        XCTAssertEqual(s.pinnedRoots(ofSpace: space).map(\.id).last, item.id, "Arc pins a new note, here at the bottom")
        XCTAssertEqual(item.displayTitle, "New Note")
        XCTAssertEqual(t.title, "New Note")
        XCTAssertEqual(s.space(space)?.lastActiveTabID, t.id)
        let id = try XCTUnwrap(NoteURL.noteID(t.url))
        XCTAssertNotNil(s.note(id))
        XCTAssertTrue(s.isNoteTab(t.id))
        XCTAssertEqual(s.navigationDecision(forTab: t.id), .openTodayTab)

        var changes: [StoreChange] = []
        let o = s.observe { changes.append($0) }
        s.updateNote(id, document: NoteDocument(lines: ["Shopping", "eggs"]))
        s.removeObserver(o)
        XCTAssertEqual(s.tab(t.id)?.title, "Shopping")
        XCTAssertEqual(s.item(item.id)?.pageTitle, "Shopping")
        XCTAssertEqual(s.item(item.id)?.displayTitle, "Shopping")
        XCTAssertTrue(changes.allSatisfy(\.contentOnly), "typing never rebuilds the sidebar")
        XCTAssertTrue(s.hasPendingWrites, "typing is written with the next flush")
        XCTAssertFalse(s.canUndo, "the editor undoes its own typing; the store's undo stays the sidebar's")

        let today = try s.createNote(inSpace: space, pinned: false)
        XCTAssertNil(today.itemID)
        XCTAssertEqual(s.todayTabs(ofSpace: space).first?.id, today.id)
    }

    func testClosingAnEmptyNoteDeletesItAndUndoBringsItBack() throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let empty = try s.createNote(inSpace: space, pinned: false)
        let emptyID = try XCTUnwrap(NoteURL.noteID(empty.url))
        XCTAssertEqual(try s.closeTab(empty.id), .deleted)
        XCTAssertNil(s.tab(empty.id))
        XCTAssertNil(s.note(emptyID))
        XCTAssertTrue(s.archivedEntries.isEmpty, "Arc: an empty note isn't kept in the Archive")
        _ = try s.undo()
        XCTAssertNotNil(s.tab(empty.id))
        XCTAssertNotNil(s.note(emptyID))

        let full = try s.createNote(inSpace: space, pinned: false)
        let fullID = try XCTUnwrap(NoteURL.noteID(full.url))
        s.updateNote(fullID, document: NoteDocument(lines: ["Keep me"]))
        guard case .archived(let entry) = try s.closeTab(full.id) else { return XCTFail("a note with text is archived") }
        XCTAssertEqual(s.state.archive[entry]?.title, "Keep me")
        XCTAssertNotNil(s.note(fullID), "an archived note keeps what it says")
        let back = try s.restoreArchived(entry, fallbackSpaceID: space)
        XCTAssertEqual(back.url, full.url)
        XCTAssertEqual(s.note(forTab: back.id)?.document.title, "Keep me")
    }

    func testATodayNoteIsAPaneOfATodaySplitOnly() throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let page = try s.openTab(url: "https://example.com/", inSpace: space)
        let other = try s.openTab(url: "https://example.org/", inSpace: space)
        let note = try s.createNote(inSpace: space, pinned: false)
        let pinnedNote = try s.createNote(inSpace: space)
        // New Note in Split: a Today note beside the page, focused; one more pane joins.
        let x = try s.createSplit([page.id, note.id], inSpace: space, focused: note.id, order: s.tab(page.id)?.order)
        XCTAssertEqual(s.split(x.id)?.tabIDs, [page.id, note.id])
        XCTAssertEqual(s.split(x.id)?.focusedTabID, note.id)
        try s.addToSplit(x.id, tabID: other.id)
        XCTAssertEqual(s.split(x.id)?.tabIDs.count, 3)
        // A pinned note is never a pane, and a split holding a note is never pinned or a Favorite.
        XCTAssertThrowsError(try s.createSplit([other.id, pinnedNote.id], inSpace: space))
        let third = try s.openTab(url: "https://example.net/", inSpace: space)
        let y = try s.createSplit([other.id, third.id], inSpace: space)
        XCTAssertThrowsError(try s.addToSplit(y.id, tabID: pinnedNote.id))
        XCTAssertThrowsError(try s.move(.split(x.id), to: .pinned(spaceID: space, parentID: nil, index: 0)))
        XCTAssertThrowsError(try s.move(.split(x.id), to: .favorites(profileID: s.defaultProfile.id, index: 0)))
        XCTAssertNil(s.split(x.id)?.itemID)
        XCTAssertTrue(s.split(x.id)?.tabIDs.contains(note.id) == true)
        // Drags still don't put a note in a split, nor onto a note's row.
        let loose = try s.createNote(inSpace: space, pinned: false)
        XCTAssertThrowsError(try s.move(.tab(loose.id), to: .split(spaceID: space, target: page.id, leading: false)))
        XCTAssertThrowsError(try s.move(.tab(loose.id), to: .split(spaceID: space, target: note.id, leading: false)))
        // Separate All Tabs: the note is a Today row of its own again, as it was.
        try s.separateSplit(x.id)
        XCTAssertNil(s.split(containing: note.id))
        XCTAssertTrue(s.tab(note.id)?.isToday == true && s.note(forTab: note.id) != nil)
    }

    func testNotesStayOutOfFavoritesAndSplitsAndCopiesGetTheirOwnNote() throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let page = try s.openTab(url: "https://example.com/", inSpace: space)
        let note = try s.createNote(inSpace: space, pinned: false)
        let noteID = try XCTUnwrap(NoteURL.noteID(note.url))
        s.updateNote(noteID, document: NoteDocument(lines: ["Original"]))
        let profile = s.defaultProfile.id
        XCTAssertThrowsError(try s.move(.tab(note.id), to: .favorites(profileID: profile, index: 0)))
        XCTAssertThrowsError(try s.copy(.tab(note.id), to: .favorites(profileID: profile, index: 0)))
        // Drags never make a split of a note (New Note in Split does: testATodayNoteIsAPaneOfATodaySplitOnly).
        XCTAssertThrowsError(try s.move(.tab(note.id), to: .split(spaceID: space, target: page.id, leading: true)))
        XCTAssertThrowsError(try s.move(.tab(page.id), to: .split(spaceID: space, target: note.id, leading: true)))
        XCTAssertTrue(s.state.splits.isEmpty)
        XCTAssertTrue(s.favorites(ofProfile: profile).isEmpty)

        // ⌥-drag, Duplicate (Today and pinned) and a duplicated folder: each copy is a note of its own.
        let copyID = try s.copy(.tab(note.id), to: .today(spaceID: space, index: 0))
        let dup = try s.duplicateTab(note.id)
        try s.togglePin(note.id, inSpace: space)
        let item = try XCTUnwrap(s.tab(note.id)?.itemID)
        let folder = try s.createFolder(inSpace: space, containing: [.item(item)])
        let dupItem = try s.duplicateItem(item)
        let dupFolder = try s.duplicateItem(folder.id)
        let urls = [s.tab(copyID)?.url, dup.url, dupItem.savedURL, s.children(of: .pinned(spaceID: space), parent: dupFolder.id).first?.savedURL]
        XCTAssertEqual(Set(urls.compactMap { $0 }).count, 4)
        for u in urls {
            let id = try XCTUnwrap(NoteURL.noteID(u))
            XCTAssertNotEqual(id, noteID)
            XCTAssertEqual(s.note(id)?.document.title, "Original")
        }
        // Editing the original leaves the copies alone.
        s.updateNote(noteID, document: NoteDocument(lines: ["Changed"]))
        XCTAssertEqual(s.note(NoteURL.noteID(dup.url))?.document.title, "Original")
        XCTAssertEqual(s.allLinks(inFolder: folder.id), [], "a folder's links leave notes out")
    }

    func testOrphanNotesGoAtLaunchAndArchivedNotesOutliveArchivePruning() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let space = s.selectedSpace.id
        let kept = try s.createNote(inSpace: space)
        let archived = try s.createNote(inSpace: space, pinned: false)
        let deleted = try s.createNote(inSpace: space)
        for t in [kept, archived, deleted] {
            s.updateNote(NoteURL.noteID(t.url)!, document: NoteDocument(lines: ["text of \(t.id)"]))
        }
        _ = try s.closeTab(archived.id)
        try s.deleteItem(s.tab(deleted.id)!.itemID!)
        let old = try s.openTab(url: "https://old.example/", inSpace: space)
        _ = try s.closeTab(old.id)
        clock.advance(200 * 86400)
        XCTAssertEqual(try s.pruneArchive(), 1, "the page goes, the note stays")
        XCTAssertEqual(s.archivedEntries.map(\.url), [archived.url])

        XCTAssertEqual(try s.removeOrphanNotes(), [], "nothing while ⌘Z could bring a row back")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        do {
            let disk = try SpacesStore(path: path)
            try disk.restore(fromBackup: s.exportJSON())
            try disk.flush()
        }
        let relaunched = try SpacesStore(path: path)
        let removed = try relaunched.removeOrphanNotes()
        XCTAssertEqual(removed.map(\.id), [NoteURL.noteID(deleted.url)!])
        XCTAssertNotNil(relaunched.note(NoteURL.noteID(kept.url)))
        XCTAssertNotNil(relaunched.note(NoteURL.noteID(archived.url)))
        XCTAssertEqual(relaunched.noteImageFiles, [])
    }

    func testNotesPersistAcrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        let d = doc([NoteBlock(kind: .heading1, runs: [NoteRun("Persisted")]),
                     NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("ticked", marks: [.bold])])])
        var tabID = ""
        do {
            let s = try SpacesStore(path: path)
            let t = try s.createNote(inSpace: s.selectedSpace.id)
            tabID = t.id
            s.updateNote(NoteURL.noteID(t.url)!, document: d)
            try s.flush()
        }
        let s = try SpacesStore(path: path)
        XCTAssertEqual(s.note(forTab: tabID)?.document, d)
        XCTAssertEqual(s.tab(tabID)?.title, "Persisted")
        XCTAssertTrue(s.unreadableRows.isEmpty)
    }

    // MARK: Schema 2, only with notes (lead, 2026-11-07): going back to 0.1.2 stays safe until a note is made

    /// What Airc 0.1.2 (schema 1) makes of a store file: its mark, and whether every row is of a kind it knows.
    private func asOldReader(_ path: String) throws -> (newer: Bool, unknownKinds: Set<String>) {
        let db = try Database(path: path)
        let mark = (try db.query("SELECT value FROM meta WHERE key='schema'").first?.first as? String).flatMap { Int($0) }
        let known: Set<String> = ["profile", "space", "item", "tab", "archive", "split"]
        let kinds = Set(try db.query("SELECT DISTINCT kind FROM entities").compactMap { $0.first as? String })
        return (SpacesStore.isNewer(mark, than: 1), kinds.subtracting(known))
    }

    private func mark(_ path: String) throws -> String? {
        try Database(path: path).query("SELECT value FROM meta WHERE key='schema'").first?.first as? String
    }

    private func storePath() -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-notes-\(UUID().uuidString)")
        return (dir, dir.appendingPathComponent("spaces.sqlite").path)
    }

    /// (a) A schema-1 store opened, used and closed by this build without a note stays schema 1: 0.1.2 opens it with no
    /// newer-data note and reads every row, byte for byte as before.
    func testAStoreWithoutNotesStaysSchemaOne() throws {
        let (dir, path) = storePath()
        defer { try? FileManager.default.removeItem(at: dir) }
        var before: [[String]] = []
        do {
            let s = try SpacesStore(path: path)
            XCTAssertEqual(s.schemaMark, 1, "a new store is schema 1")
            let t = try s.openTab(url: "https://example.com/", inSpace: s.selectedSpace.id)
            try s.togglePin(t.id, inSpace: s.selectedSpace.id)
            try s.flush()
        }
        XCTAssertEqual(try mark(path), "1")
        before = try Database(path: path).query("SELECT kind, id, body FROM entities ORDER BY kind, id").map { $0.map { "\($0 ?? "nil")" } }
        do {
            // This build again: used (a tab opened and closed, Spaces, backups), no note.
            let s = try SpacesStore(path: path)
            XCTAssertEqual(s.schemaMark, 1)
            XCTAssertNil(s.newerSchemaVersion)
            let t = try s.openTab(url: "https://example.org/", inSpace: s.selectedSpace.id)
            _ = try s.closeTab(t.id)
            _ = try s.exportJSON()
            try s.flush()
        }
        XCTAssertEqual(try mark(path), "1", "using this build without a note leaves the mark alone")
        let old = try asOldReader(path)
        XCTAssertFalse(old.newer, "0.1.2 shows no \"Some data is from a newer Airc\"")
        XCTAssertEqual(old.unknownKinds, [], "0.1.2 reads every row")
        let after = try Database(path: path).query("SELECT kind, id, body FROM entities WHERE kind IN ('profile','item') ORDER BY kind, id")
            .map { $0.map { "\($0 ?? "nil")" } }
        XCTAssertEqual(after, before.filter { ["profile", "item"].contains($0[0]) }, "the earlier rows read as they were")
        XCTAssertTrue(try Database(path: path).query("SELECT 1 FROM ops WHERE kind='note'").isEmpty)

        // A store ffa8abf opened (it raised every mark at open) and that never had a note goes back to 1.
        try Database(path: path).run("UPDATE meta SET value='2' WHERE key='schema'")
        XCTAssertEqual(try SpacesStore(path: path).schemaMark, 1)
        XCTAssertEqual(try mark(path), "1")
    }

    /// (b) The first note raises the mark to 2 in the transaction that writes it; this build reads its own 2 as its own.
    /// (c) Deleting the last note leaves it at 2: the store has had notes (their deletes stay in the op log) and the
    /// mark only rises (SpacesStore.schemaMark).
    func testTheFirstNoteRaisesTheMarkAndItStays() throws {
        let (dir, path) = storePath()
        defer { try? FileManager.default.removeItem(at: dir) }
        var noteTab = ""
        do {
            let s = try SpacesStore(path: path)
            XCTAssertEqual(s.schemaMark, 1)
            let t = try s.createNote(inSpace: s.selectedSpace.id)
            noteTab = t.id
            XCTAssertEqual(s.schemaMark, 2)
            XCTAssertEqual(try mark(path), "2", "written with the note")
            // A failed write leaves the mark where it was, with the note pending; the next write raises it.
            let other = try SpacesStore(path: nil)
            other.failNextFlushes = 1
            XCTAssertThrowsError(try other.createNote(inSpace: other.selectedSpace.id))
            XCTAssertEqual(other.schemaMark, 1)
            XCTAssertFalse(other.state.notes.isEmpty)
            try other.flush()
            XCTAssertEqual(other.schemaMark, 2)
        }
        do {
            let s = try SpacesStore(path: path)
            XCTAssertEqual(s.schemaMark, 2)
            XCTAssertNil(s.newerSchemaVersion, "this build's own mark isn't newer data")
            XCTAssertTrue(s.unreadableRows.isEmpty)
            XCTAssertTrue(try asOldReader(path).newer, "0.1.2 now keeps the notes for this build and says so")
            // (c) The last note deleted: its pinned row now, its note at the next launch's clean-up.
            try s.deleteItem(XCTUnwrap(s.tab(noteTab)?.itemID))
            try s.flush()
        }
        do {
            let s = try SpacesStore(path: path)
            XCTAssertEqual(try s.removeOrphanNotes().count, 1)
            XCTAssertTrue(s.state.notes.isEmpty)
        }
        XCTAssertTrue(try Database(path: path).query("SELECT 1 FROM entities WHERE kind='note'").isEmpty)
        XCTAssertEqual(try SpacesStore(path: path).schemaMark, 2, "the mark stays 2 after the last note")
        XCTAssertEqual(try mark(path), "2")
    }

    /// A backup's notes, restored into a store without any, raise its mark as they're written (the async restore).
    @MainActor
    func testRestoringNotesRaisesTheMark() async throws {
        let (dir, path) = storePath()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeStore()
        let t = try source.createNote(inSpace: source.selectedSpace.id)
        source.updateNote(NoteURL.noteID(t.url)!, document: NoteDocument(lines: ["Restored"]))
        let bytes = try source.exportJSON()
        let s = try SpacesStore(path: path)
        XCTAssertEqual(s.schemaMark, 1)
        _ = try await s.restoreBackup(bytes, savingCurrentTo: dir.appendingPathComponent("Backups"))
        XCTAssertEqual(s.schemaMark, 2)
        XCTAssertEqual(try mark(path), "2")
        XCTAssertEqual(s.note(forTab: t.id)?.document.title, "Restored")
    }

    /// (d) A backup without notes is schema 1 and shaped as 0.1.2's (no `notes` key), so 0.1.2 restores it; one with
    /// notes (or a note's row) is schema 2, which 0.1.2 refuses instead of restoring without them.
    func testBackupsAreSchemaOneWithoutNotes() throws {
        let s = try makeStore()
        _ = try s.openTab(url: "https://example.com/", inSpace: s.selectedSpace.id)
        let plain = try s.exportJSON()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertNil((json["state"] as? [String: Any])?["notes"], "no notes key: the state as 0.1.2 wrote it")
        let plainVersion = try SpacesStore.readBackup(plain).version
        XCTAssertEqual(plainVersion, 1)
        XCTAssertTrue((1...1).contains(plainVersion), "0.1.2's check accepts it")

        let t = try s.createNote(inSpace: s.selectedSpace.id)
        let withNote = try s.exportJSON()
        let noteVersion = try SpacesStore.readBackup(withNote).version
        XCTAssertEqual(noteVersion, 2)
        XCTAssertFalse((1...1).contains(noteVersion), "0.1.2 refuses it")
        // The recovery points and daily backups are the same export.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airc-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try s.writeBackup(to: folder, purpose: .manual)
        XCTAssertEqual(try SpacesStore.readBackup(Data(contentsOf: file)).version, 2)
        // Its note gone (deleted with its row): schema 1 again.
        try s.deleteItem(XCTUnwrap(s.tab(t.id)?.itemID))
        try s.perform(nil) { s.remove(Note.self, NoteURL.noteID(t.url)!) }
        XCTAssertEqual(try SpacesStore.readBackup(s.exportJSON()).version, 1)
        // A state with a note's row and no note (a damaged one) still needs schema 2.
        var state = StoreState()
        state.tabs["x"] = LiveTab(id: "x", profileID: "p", spaceID: "s", url: NoteURL.make("gone"))
        XCTAssertEqual(state.requiredSchema, 2)
    }

    @MainActor
    func testBackupsCarryNotesBothWaysAndOldBackupsStillRestore() async throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let pinned = try s.createNote(inSpace: space)
        let d = doc([NoteBlock(kind: .bullet, runs: [NoteRun("in the backup")]),
                     NoteBlock(runs: [NoteRun(image: NoteImage(file: String(repeating: "c", count: 64) + ".png", width: 640, height: 400))])])
        s.updateNote(NoteURL.noteID(pinned.url)!, document: d)
        let archived = try s.createNote(inSpace: space, pinned: false)
        s.updateNote(NoteURL.noteID(archived.url)!, document: NoteDocument(lines: ["archived"]))
        _ = try s.closeTab(archived.id)
        let bytes = try s.exportJSON()
        let backup = try SpacesStore.readBackup(bytes)
        XCTAssertEqual(backup.version, 2)
        XCTAssertEqual(backup.state.notes.count, 2)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(String(repeating: "c", count: 64) + ".png"),
                      "the backup names the picture files the notes need")

        // Restore over a store with other notes: exactly the backup's notes come back, both ways of restoring.
        for async in [false, true] {
            let other = try makeStore()
            _ = try other.createNote(inSpace: other.selectedSpace.id)
            if async {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: folder) }
                _ = try await other.restoreBackup(bytes, savingCurrentTo: folder)
            } else {
                try other.restore(fromBackup: bytes)
            }
            XCTAssertEqual(other.state.notes, backup.state.notes, "async: \(async)")
            XCTAssertEqual(other.note(forTab: pinned.id)?.document, d)
            let entry = try XCTUnwrap(other.archivedEntries.first { NoteURL.isNote($0.url) })
            let back = try other.restoreArchived(entry.id, fallbackSpaceID: other.selectedSpace.id)
            XCTAssertEqual(other.note(forTab: back.id)?.document.title, "archived")
        }

        // A schema 1 backup (no notes key) restores, and takes the notes it never had away with their rows.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: makeStore().exportJSON()) as? [String: Any])
        json["version"] = 1
        var state = try XCTUnwrap(json["state"] as? [String: Any])
        state["notes"] = nil
        json["state"] = state
        let v1 = try JSONSerialization.data(withJSONObject: json)
        try s.restore(fromBackup: v1)
        XCTAssertTrue(s.state.notes.isEmpty)
        XCTAssertFalse(s.state.tabs.values.contains { NoteURL.isNote($0.url) })
    }
}
