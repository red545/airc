// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// Notes stay on this Mac for now (docs/sync.md, docs/user/notes.md): the adapter sends nothing about them, and nothing
/// another Mac does (a deleted folder or Space, Replace this Mac's sidebar) removes, moves or archives one.
final class SyncNotesTests: XCTestCase {
    private func noteID(_ t: LiveTab) -> String { NoteURL.noteID(t.url)! }

    private func sent(_ ops: [SyncOperation]) throws -> String { String(decoding: try JSONEncoder().encode(ops), as: UTF8.self) }

    func testNotesAreNeverSentAndOtherMacsNeverRemoveThem() throws {
        let store = try makeStore()
        let work = try store.createSpace(name: "Work")
        let folder = try store.createFolder(named: "Docs", inSpace: work.id)
        let page = try store.openTab(url: "https://example.com/a", inSpace: work.id)
        try store.move(.tab(page.id), to: .pinned(spaceID: work.id, parentID: folder.id, index: 0))
        let pinned = try store.createNote(inSpace: work.id, parentID: folder.id)
        let today = try store.createNote(inSpace: work.id, pinned: false)
        let ideas = try store.createSpace(name: "Ideas")
        let alone = try store.createNote(inSpace: ideas.id, pinned: false)
        store.updateNote(noteID(pinned), document: NoteDocument(lines: ["Secret pinned note"]))
        store.updateNote(noteID(today), document: NoteDocument(lines: ["Secret today note"]))
        store.updateNote(noteID(alone), document: NoteDocument(lines: ["Secret lone note"]))
        let pinnedItem = try XCTUnwrap(store.tab(pinned.id)?.itemID)
        let pageItem = try XCTUnwrap(store.tab(page.id)?.itemID)

        var adapter = SyncStoreAdapter(includeToday: true), replica = SyncReplica()
        let first = try sent(adapter.capture(store.state, into: &replica, now: 1))
        XCTAssertTrue(first.contains("example.com"), "the page syncs")
        let secrets = ["airc-note", "Secret", "New Note", pinned.id, today.id, alone.id, pinnedItem]
            + [pinned, today, alone].map(noteID)
        for secret in secrets { XCTAssertFalse(first.contains(secret), secret) }
        XCTAssertEqual(adapter.excludedRows, [adapter.record(forItem: pinnedItem)], "the pinned note's row is local-only")

        // Typing, renaming, pinning, unpinning and archiving notes: still nothing goes out.
        store.updateNote(noteID(pinned), document: NoteDocument(lines: ["Secret, edited"]))
        try store.renameItem(pinnedItem, to: "Secret name")
        try store.togglePin(today.id, inSpace: work.id)
        try store.togglePin(today.id, inSpace: work.id)
        let archived = try store.createNote(inSpace: work.id, pinned: false)
        store.updateNote(noteID(archived), document: NoteDocument(lines: ["Secret archived note"]))
        _ = try store.closeTab(archived.id)
        let later = try adapter.capture(store.state, into: &replica, now: 2)
        let laterSent = try sent(later)
        XCTAssertTrue(later.isEmpty, laterSent)

        // Another Mac deletes the folder, the page and both Spaces.
        var other = SyncReplica()
        try other.receive(replica.log, now: 3)
        let deletes = try [SyncRecordID(.row, adapter.record(forItem: pageItem)), SyncRecordID(.row, adapter.record(forItem: folder.id)),
                           SyncRecordID(.space, work.id), SyncRecordID(.space, ideas.id)].map {
            try other.edit($0, [.deleted: .flag(true)], now: 4)
        }
        try replica.receive(deletes, now: 5)
        let notesBefore = store.state.notes
        try store.applySync(replica, adapter: &adapter)
        adapter.rebase(store.state)
        XCTAssertNil(store.item(pageItem), "a synced row goes by its tombstone")
        XCTAssertNil(store.item(folder.id))
        XCTAssertNotNil(store.space(work.id), "a Space with a pinned note stays")
        XCTAssertNotNil(store.space(ideas.id), "a Space with a note in Today stays")
        XCTAssertEqual(store.item(pinnedItem)?.parentID, nil, "the note leaves the deleted folder for the Space's root")
        XCTAssertNotNil(store.tab(today.id))
        XCTAssertNotNil(store.tab(alone.id))
        XCTAssertEqual(store.archivedEntries.filter { NoteURL.isNote($0.url) }.count, 1, "only the note archived here")
        XCTAssertEqual(store.state.notes, notesBefore, "no note changed")

        // Replace this Mac's sidebar with a group that has none of it: every note row is still here.
        try store.applySync(SyncReplica(), adapter: &adapter, replace: true)
        adapter.rebase(store.state)
        XCTAssertNotNil(store.item(pinnedItem))
        XCTAssertNotNil(store.tab(today.id))
        XCTAssertNotNil(store.tab(alone.id))
        XCTAssertEqual(store.state.notes, notesBefore)
        let after = try sent(adapter.capture(store.state, into: &replica, now: 6))
        for secret in secrets { XCTAssertFalse(after.contains(secret), secret) }
    }

    func testANoteNeverTombstonesWhenItLeaves() throws {
        let store = try makeStore()
        let space = store.selectedSpace.id
        let note = try store.createNote(inSpace: space)
        store.updateNote(noteID(note), document: NoteDocument(lines: ["Pinned text"]))
        var adapter = SyncStoreAdapter(includeToday: true), replica = SyncReplica()
        try adapter.capture(store.state, into: &replica, now: 1)
        let item = try XCTUnwrap(store.tab(note.id)?.itemID)
        // Unpinned, closed (archived), restored, pinned again, deleted: no record is made, edited or deleted.
        try store.togglePin(note.id, inSpace: space)
        guard case .archived(let entry) = try store.closeTab(note.id) else { return XCTFail() }
        let back = try store.restoreArchived(entry, fallbackSpaceID: space)
        try store.togglePin(back.id, inSpace: space)
        try store.deleteItem(XCTUnwrap(store.tab(back.id)?.itemID))
        XCTAssertTrue(try adapter.capture(store.state, into: &replica, now: 2).isEmpty)
        XCTAssertFalse(replica.records.keys.contains { $0.id.contains(item) || $0.id.contains(note.id) || $0.id.contains(back.id) })
    }
}
