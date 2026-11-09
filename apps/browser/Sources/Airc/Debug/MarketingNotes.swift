// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of Notes (docs/user/notes.md), the marketing scenario's part "notes" (`scripts/marketing-shots.sh
/// --parts notes`):
///   - notes: Travel with a note pinned in its sidebar, "Lisbon plan": a few lines, a checklist with one tick, and a
///     Capture of the synthetic trip-planning page's illustration (MarketingServer's trips.aircbrowser.com/lisbon, the
///     Capture shot's page) pasted into it. Fixture text only; the page's tab is closed again before the shot.
///   - notes-split: New Note in Split: the same trip page with a note beside it, "Packing for Lisbon", being written.
extension SnapshotRunner {
    func mkNotesShots(_ d: MarketingDemo) {
        let board = NSPasteboard(name: NSPasteboard.Name("org.airc.marketing.notes.\(getpid())"))
        var pageTab = "", noteTab = ""
        mkShow(d, "travel", nil)
        run { [self] in
            CaptureSession.pasteboard = { board }
            CaptureSession.recordUse = { _ in }
            pageTab = (try? c.store.openTab(url: MarketingDemo.site("trips", "/lisbon"), inSpace: c.currentSpaceID, title: "Lisbon, four days"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(pageTab, focus: false)
        }
        mkSettleShown()
        run { [self] in c.startCapture() }
        step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
        // The hero card, as in the Capture shot, copied to the run's own pasteboard.
        step { [self] done in
            guard let s = CaptureSession.active(in: c.window), let page = s.shots.first else {
                note("marketing: MISSING notes: Capture didn't start")
                return done()
            }
            s.tab(page.tab, evaluate: "(function(){var r=document.querySelector('.sky').getBoundingClientRect();return [r.left,r.top,r.width,r.height]})()") { box in
                let o = s.overlay
                let fallback = CGRect(x: page.frame.minX + 50, y: page.frame.minY + 150, width: page.frame.width * 0.5, height: 400)
                o.selection = (box.flatMap { CaptureGeometry.elementRect(css: $0, in: page.frame, zoom: page.tab.zoomFactor, bounds: o.bounds) } ?? fallback).integral
                o.update()
                s.confirm()
                o.bar.copyButton.action?()
                done()
            }
        }
        wait(0.6)
        run { [self] in
            CaptureSession.active(in: c.window)?.cancel()
            let doc = NoteDocument(blocks: [
                NoteBlock(kind: .heading1, runs: [NoteRun("Lisbon plan")]),
                NoteBlock(runs: [NoteRun("Trams, tiles and the long light over the Tagus. "), NoteRun("Golden hour from Santa Luzia", marks: [.bold]),
                                 NoteRun(", then dinner in Alfama.")]),
                NoteBlock(kind: .heading3, runs: [NoteRun("Before we go")]),
                NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Book the Sintra train")]),
                NoteBlock(kind: .checkbox, runs: [NoteRun("Tram 28 before nine")]),
                NoteBlock(kind: .checkbox, runs: [NoteRun("Pastéis de Belém, "), NoteRun("the original", marks: [.italic])]),
                NoteBlock(kind: .heading3, runs: [NoteRun("The view")]),
                NoteBlock(),
            ])
            guard let t = try? c.store.createNote(inSpace: c.currentSpaceID, document: doc) else { return note("marketing: MISSING notes: no note") }
            noteTab = t.id
            // The page's tab goes: the shot is about the note (and its title isn't twice in the sidebar).
            if !pageTab.isEmpty { c.closeTab(pageTab); pageTab = "" }
            c.show(noteTab, focus: false)
            guard let tv = c.shownNote?.textView else { return note("marketing: MISSING notes: no editor") }
            tv.isContinuousSpellCheckingEnabled = false   // place names aren't misspelled
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            if !tv.readSelection(from: board) { note("marketing: MISSING notes: no Capture to paste") }
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.scrollToBeginningOfDocument(nil)
            c.window.makeFirstResponder(nil)
            c.reloadAll(animated: false)
        }
        // "Copied Capture" fades first.
        wait(3.0)
        mkWindowShot("notes")
        run { [self] in
            if !noteTab.isEmpty, let item = c.store.tab(noteTab)?.itemID { c.forgetPage(noteTab, close: true); try? c.store.deleteItem(item) }
            if !pageTab.isEmpty { c.closeTab(pageTab) }
        }
        wait(0.4)

        // New Note in Split: the trip page, and a note beside it (Notes/NoteSplit.swift).
        var splitPage = "", splitNote = ""
        run { [self] in
            splitPage = (try? c.store.openTab(url: MarketingDemo.site("trips", "/lisbon"), inSpace: c.currentSpaceID, title: "Lisbon, four days"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(splitPage, focus: false)
        }
        mkSettleShown()
        run { [self] in
            let doc = NoteDocument(blocks: [
                NoteBlock(kind: .heading1, runs: [NoteRun("Packing for Lisbon")]),
                NoteBlock(runs: [NoteRun("Four days, "), NoteRun("mostly walking", marks: [.bold]), NoteRun(": the hills are steep.")]),
                NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Comfortable shoes")]),
                NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("A light jacket for the evenings")]),
                NoteBlock(kind: .checkbox, runs: [NoteRun("Sunglasses")]),
                NoteBlock(kind: .checkbox, runs: [NoteRun("Tram 28 tickets")]),
                NoteBlock(kind: .heading3, runs: [NoteRun("From the guide")]),
                NoteBlock(kind: .bullet, runs: [NoteRun("Miradouro de Santa Luzia at sunset")]),
                NoteBlock(kind: .bullet, runs: [NoteRun("Pastéis de Belém, "), NoteRun("before the queue", marks: [.italic])]),
            ])
            guard !splitPage.isEmpty, let t = try? c.store.createNote(inSpace: c.currentSpaceID, pinned: false, document: doc) else {
                return note("marketing: MISSING notes-split: no note")
            }
            splitNote = t.id
            c.addPane(splitNote, nextTo: splitPage, axis: .horizontal)
            guard c.shownSplitID != nil, let tv = c.shownNote?.textView else { return note("marketing: MISSING notes-split: no split") }
            tv.isContinuousSpellCheckingEnabled = false   // place names aren't misspelled
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            c.reloadAll(animated: false)
        }
        wait(2.0)
        mkWindowShot("notes-split")
        run { [self] in
            if let x = c.store.split(containing: splitPage) { try? c.store.separateSplit(x.id) }
            // Emptied first, so closing deletes it rather than leaving it in the Library's Archive for later shots.
            if let id = NoteURL.noteID(c.store.tab(splitNote)?.url) { c.store.updateNote(id, document: NoteDocument()) }
            if !splitNote.isEmpty { c.forgetPage(splitNote, close: true); _ = try? c.store.closeTab(splitNote) }
            if !splitPage.isEmpty { c.closeTab(splitPage) }
        }
        wait(0.4)
    }
}
#endif
