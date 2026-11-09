// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Part of `--script notes` and `notes-read` (docs/user/notes.md, Notes/NoteSplit.swift): Arc's New Note (in Split).
///   - beside a loopback page: a Today split of the page and a new note, the page the same engine page as before, the
///     note's editor in its pane and the keyboard in the note; the Command Bar and File menu offer it;
///   - typing saves; the keyboard moves between the panes (a pane's focus, ⌘] wrapping) and back into the note;
///   - ⌘W on the note pane archives it (it has text) and the page stays alone; ⌘Z brings it back;
///   - notes-read: after a relaunch the split is there with the note as it was, its editor in its pane.
extension SnapshotRunner {
    private var notesSplitExpected: URL { dir.appendingPathComponent("notes-split.json") }

    func notesSplitChecks() {
        var server: LocalPageServer?
        var base = ""
        var pageTab = "", noteTab = ""
        var page: EngineTab?
        let store = { self.c.store }
        let tv = { self.c.shownNote?.textView }
        step { [self] done in
            server = LocalPageServer(responses: ["/beside.html": .init(body: "<title>Beside</title><p>The trip page.</p>")])
            server?.start { port in
                base = port.map { "http://localhost:\($0)" } ?? ""
                if base.isEmpty { self.note("notes split: no loopback server") }
                done()
            }
        }
        run { [self] in
            pageTab = (try? store().openTab(url: base + "/beside.html", inSpace: c.currentSpaceID))?.id ?? ""
            c.show(pageTab)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: pageTab)?.isLoading == false }, timeout: 8) { done() } }
        run { [self] in
            page = c.engineTab(for: pageTab)
            check(c.canAddNoteInSplit && c.commandActions().contains { $0.title == "New Note in Split" },
                  "notes split: beside a page, the Command Bar offers New Note in Split")
            let item = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first { $0.title == "New Note in Split" } as? CommandMenuItem
            check(item.map { $0.validateMenuItem($0) } == true, "notes split: File › New Note in Split, on beside a page")
            let before = store().state.notes.count
            c.commandActions().first { $0.title == "New Note in Split" }?.run()
            noteTab = c.shownTabID ?? ""
            let x = store().split(containing: pageTab)
            check(store().state.notes.count == before + 1 && store().isNoteTab(noteTab) && store().tab(noteTab)?.isToday == true,
                  "notes split: a new Today note")
            check(x?.tabIDs == [pageTab, noteTab] && x?.itemID == nil && c.shownSplitID == x?.id && x?.focusedTabID == noteTab,
                  "notes split: a Today split of the page and the note, the note's pane focused (\(x?.tabIDs ?? []))")
            check(page != nil && c.engineTab(for: pageTab) === page && page?.isClosed == false && c.engineTab(for: noteTab) == nil,
                  "notes split: the page beside it is the same page as before; the note has none")
            let host = c.splitContainer.pane(for: noteTab)?.host
            check(host != nil && c.shownNote?.view.superview === host && c.card.isHidden && !c.splitContainer.isHidden,
                  "notes split: the note's editor is in its pane")
            check(tv() != nil && c.window.firstResponder === tv(), "notes split: the keyboard is in the note (\(c.window.firstResponder.map { "\(type(of: $0))" } ?? "nothing"))")
            check(!c.canAddNoteInSplit || store().split(containing: noteTab)?.tabIDs.count ?? 0 < Split.maxPanes,
                  "notes split: more room in the split is offered only while there is some")
            tv()?.insertText("Beside the page", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        wait(0.2)
        run { [self] in
            check(store().note(forTab: noteTab)?.document.title == "Beside the page", "notes split: typing in the pane saves the note")
            c.focusSplitPane(pageTab)
            check(c.shownTabID == pageTab && c.window.firstResponder !== tv() && store().split(containing: pageTab)?.focusedTabID == pageTab,
                  "notes split: the page's pane takes the keyboard")
            c.focusAdjacentPane(1)
            check(c.shownTabID == noteTab && tv() != nil && c.window.firstResponder === tv(), "notes split: ⌘] wraps back into the note, which has the keyboard")
            check(c.shownNote?.noteID == NoteURL.noteID(store().tab(noteTab)?.url), "notes split: Find, Print and Export act on the note in its pane")
        }
        // ⌘W on the note's pane: archived (it has text); the page alone again. ⌘Z: back.
        run { [self] in
            c.closeTab(noteTab)
            let archived = store().state.archive.values.contains { NoteURL.isNote($0.url) && $0.title == "Beside the page" }
            check(store().tab(noteTab) == nil && archived && store().split(containing: pageTab) == nil && c.shownSplitID == nil
                  && c.notePaneViews.isEmpty && c.engineTab(for: pageTab) === page,
                  "notes split: ⌘W archives the note and the page is a tab of its own again, the same page (shown: \(c.shownTabID == pageTab ? "the page" : "another tab"))")
            c.undo()
        }
        wait(0.3)
        run { [self] in
            let back = store().state.tabs.values.first { $0.isToday && store().note(forTab: $0.id)?.document.title == "Beside the page" }
            check(back != nil, "notes split: ⌘Z brings the note back as it was")
            if let back {
                noteTab = back.id
                if store().split(containing: noteTab) == nil {
                    note("notes split: ⌘Z brought the note back as a tab of its own; it goes beside the page again")
                    c.addPane(noteTab, nextTo: pageTab, axis: .horizontal)
                } else {
                    c.show(noteTab)
                }
            }
            check(store().split(containing: pageTab)?.tabIDs == [pageTab, noteTab] && c.shownNote?.view.superview === c.splitContainer.pane(for: noteTab)?.host,
                  "notes split: the note is beside the page again")
            try? store().flush()
            let doc = store().note(forTab: noteTab)?.document
            let expected: [String: Any] = ["page": pageTab, "note": noteTab,
                                           "doc": (doc.flatMap { try? JSONEncoder().encode($0) }).map { String(decoding: $0, as: UTF8.self) } ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: expected) { try? data.write(to: notesSplitExpected) }
            server?.stop()
        }
    }

    /// notes-read: the split as the last run left it.
    func notesSplitReadChecks() {
        run { [self] in
            let e = (try? Data(contentsOf: notesSplitExpected)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            guard let pageTab = e["page"] as? String, let noteTab = e["note"] as? String, let json = e["doc"] as? String,
                  let doc = try? JSONDecoder().decode(NoteDocument.self, from: Data(json.utf8)) else {
                return check(false, "notes-read split: notes-split.json from --script notes")
            }
            check(c.store.split(containing: noteTab)?.tabIDs == [pageTab, noteTab] && c.store.note(forTab: noteTab)?.document == doc,
                  "notes-read split: after a relaunch the note is beside the page, as it was")
            c.show(noteTab)
            check(c.shownSplitID != nil && c.shownNote?.textView.document == doc && c.shownNote?.view.superview === c.splitContainer.pane(for: noteTab)?.host,
                  "notes-read split: shown, its editor in its pane")
        }
    }
}
#endif
