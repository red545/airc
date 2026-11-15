// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script parityp13b`, then `parityp13b-relaunch` in a fresh process on the same data dir (both engines): P13b, the
/// rest of Notes (audit row N05). Synthetic pages and fixture text only; real clicks, keys and drags through the window.
///   1. The title field: empty, it shows the first line; a click and typing name the note, and its sidebar row and the
///      window title follow as it's typed; Return hands the keyboard to the text; ⌘Z there takes the title back (the
///      row shows the first line again) and redo puts it back; Esc drops what was typed; emptied, the first line names
///      the note again; a rename of a pinned note's row shows in its field.
///   2. A note's row dragged onto the right half of the page's row: page | note, shown, the note's editor in its pane
///      with the keyboard.
///   3. Dragged out again by its pane's handle onto the end of Today: a row of its own, the page alone on screen.
///   4. The note's row dragged over the page's right edge: page | note again, the editor focused (kept for the relaunch).
///   5. A note's row dragged onto the middle of a pinned split's row, then of a Favorite split's tile: one more pane each
///      time, shown, the note's editor focused.
///   Relaunch: the titles, the Today split with its note and the pinned and Favorite splits' notes are all back; showing
///   the split puts the editor in its pane with the title in its field; no Command Bar over the restored split (polish4).
extension SnapshotRunner {
    func parityP13bScenario() {
        if script == "parityp13b-relaunch" { return parityP13bRelaunch() }
        var sid = "", pageTab = "", noteTab = "", noteID = "", pinnedNoteTab = "", pinnedItem = ""
        var pinnedSplit = "", favoriteSplit = "", splitNoteTab = "", favoriteNoteTab = ""
        let store = { self.c.store }
        func editor(_ tab: String) -> NoteEditor? { NoteURL.noteID(store().tab(tab)?.url).flatMap { NoteCenter.shared.existingEditor($0) } }
        func field() -> NoteTitleField? { editor(noteTab)?.view.titleField }
        func rowTitle(_ tab: String) -> String {
            guard let p = c.pageView(for: sid) else { return "?" }
            p.layoutSubtreeIfNeeded()
            let row = p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.tabID == tab || ($0.entry?.item?.id != nil && $0.entry?.item?.id == store().tab(tab)?.itemID) }
            return row?.titleField.stringValue ?? "no row"
        }
        /// A click in the title field just after its text (or its placeholder's start), as a person clicks to type on.
        func clickTitle(_ done: @escaping () -> Void) {
            guard let f = field() else { return done() }
            let w = (f.stringValue as NSString).size(withAttributes: [.font: NoteTitleField.font]).width
            click(at: f.convert(NSPoint(x: min(f.bounds.width - 4, w + 12), y: f.bounds.midY), to: nil), in: c.window, done)
        }
        /// A ⌘ key as the menu bar takes it in an active app: the Edit menu's item for the key, its action sent up our
        /// window's responder chain. (A check app launched in the background, `open -g`, has no key window, so posted ⌘
        /// keys and nil-targeted menu actions never reach the window's first responder by themselves.)
        func menuKey(_ chars: String, _ mods: NSEvent.ModifierFlags = .command) {
            run { [self] in
                let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
                guard let item = items.first(where: { $0.keyEquivalent == chars && $0.keyEquivalentModifierMask == mods && !$0.isAlternate }),
                      let action = item.action else { return note("parityp13b: no menu item has \(chars) with \(mods.rawValue)") }
                let r = c.window.firstResponder
                let done = r?.tryToPerform(action, with: item) ?? false
                note("parityp13b: \(item.title) (\(chars)) went to \(Self.describe(r)): \(done)")
            }
            wait(0.15)
        }
        func titleEditing() -> Bool { field()?.currentEditor() != nil && c.window.firstResponder === field()?.currentEditor() }
        func textHasKeyboard(_ tab: String) -> Bool { editor(tab).map { c.window.firstResponder === $0.textView } ?? false }
        func doc(_ lines: [String]) -> NoteDocument {
            NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun(lines[0])])] + lines.dropFirst().map { NoteBlock(runs: [NoteRun($0)]) })
        }
        func newNote(_ lines: [String], pinned: Bool = false) -> LiveTab? { try? store().createNote(inSpace: sid, pinned: pinned, document: doc(lines)) }
        func page(_ title: String, _ color: String) -> String {
            let html = "<title>\(title)</title><body style='margin:0;background:\(color);font:20px -apple-system'><h1 style='margin:40px'>\(title)</h1></body>"
            return "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        func open(_ title: String, _ color: String) -> String {
            (try? store().openTab(url: page(title, color), inSpace: sid, activate: false, title: title))?.id ?? ""
        }
        func todayRows() -> [SidebarRowView] {
            guard let p = c.pageView(for: sid) else { return [] }
            return p.list.subviews.compactMap { $0 as? SidebarRowView }
                .filter { ($0 as? TabRowView)?.entry?.liveTab?.isToday == true || (($0 as? SplitRowView)?.split.map { $0.itemID == nil } ?? false) }
        }
        /// A window point just inside the bottom of the last Today row, the list scrolled to show it (SplitCheck's).
        func endOfToday() -> NSPoint? {
            guard let p = c.pageView(for: sid), let last = todayRows().max(by: { $0.frame.maxY < $1.frame.maxY }) else { return nil }
            p.list.scrollToVisible(last.frame.insetBy(dx: 0, dy: -16))
            p.layoutSubtreeIfNeeded()
            let end = last.convert(NSPoint(x: 60, y: last.bounds.maxY - 3), to: nil)
            let frameView = c.window.contentView?.superview
            let hit = frameView?.hitTest(frameView!.convert(end, from: nil))
            return hit.map { $0 === p.list || $0.isDescendant(of: p.list) } == true ? end : nil
        }
        func settled(_ done: @escaping () -> Void) {
            waitUntil({ !self.c.animator.isRunning("split") && !self.c.animator.isRunning("sidebar") }, timeout: 3) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done)
            }
        }
        func panes() -> String { store().split(c.shownSplitID).map { store().members(of: $0).map(\.title).joined(separator: " | ") } ?? "no split" }
        /// The note's editor is in its pane's host (not the card) and has the keyboard.
        func inPane(_ tab: String) -> Bool {
            guard let e = editor(tab), let host = c.splitContainer.pane(for: tab)?.host else { return false }
            return e.view.superview === host && !e.view.isHiddenOrHasHiddenAncestor && textHasKeyboard(tab)
        }
        /// A real drag from `from` to `to` (window points), and what went wrong when `ok` doesn't hold after it.
        func dragCase(_ what: String, from start: NSPoint, to end: NSPoint, until: @escaping () -> Bool, _ done: @escaping () -> Void) {
            var interference: String?
            let sampler = Timer(timeInterval: 0.02, repeats: true) { _ in
                for q in [start, end] where interference == nil { interference = Self.windowOverOurs(at: q, in: self.c.window) }
            }
            RunLoop.main.add(sampler, forMode: .common)
            drag(from: start, to: end) {
                sampler.invalidate()
                self.waitUntil(until, timeout: 3) {
                    settled {
                        let ok = until()
                        let detail = what + " (panes: \(panes()); keyboard: \(Self.describe(self.c.window.firstResponder)))"
                        if !ok, let interference { self.failEnv(detail, interference) } else { self.check(ok, detail) }
                        done()
                    }
                }
            }
        }

        // Setup: two pages, a Today note, a pinned note, a pinned split and a Favorite split of pages, two more notes.
        run { [self] in
            c.closeCommandBar()   // a fresh window's Command Bar: the cases are about the note and the sidebar
            sid = c.currentSpaceID
            let pid = store().profile(ofSpace: sid).id
            if let x = try? store().createSplit([open("Fav left", "#e6eef8"), open("Fav right", "#f6e9e4")], inSpace: sid) {
                _ = try? store().move(.split(x.id), to: .favorites(profileID: pid, index: 0))
                favoriteSplit = store().favorites(ofProfile: pid).first { $0.kind == .split }?.id ?? ""
            }
            if let x = try? store().createSplit([open("Pinned left", "#eaf3e6"), open("Pinned right", "#f3eef8")], inSpace: sid) {
                _ = try? store().move(.split(x.id), to: .pinned(spaceID: sid, parentID: nil, index: 0))
                pinnedSplit = store().pinnedRoots(ofSpace: sid).first { $0.kind == .split }?.id ?? ""
            }
            let pinned = newNote(["Pinned note body"], pinned: true)
            pinnedNoteTab = pinned?.id ?? ""
            pinnedItem = pinned?.itemID ?? ""
            favoriteNoteTab = newNote(["Favorite split note", "Beside two pages"])?.id ?? ""
            splitNoteTab = newNote(["Pinned split note", "Beside two pinned pages"])?.id ?? ""
            pageTab = open("Trip page", "#f4ece2")
            let n = newNote(["Packing list", "Passport, adapters, a good book"])
            noteTab = n?.id ?? ""
            noteID = NoteURL.noteID(n?.url) ?? ""
            c.reloadAll(animated: false)
            c.show(noteTab, focus: true)
            check(!favoriteSplit.isEmpty && !pinnedSplit.isEmpty && !noteID.isEmpty && !pinnedItem.isEmpty,
                  "parityp13b setup: a Favorite split, a pinned split, a pinned note and three Today notes")
        }
        step { [self] done in waitUntil({ self.c.shownNote?.noteID == noteID && field()?.window != nil }, timeout: 4) { done() } }

        // 1. The title field.
        step { [self] done in
            guard let f = field() else { check(false, "parityp13b title: the note shows its title field"); return done() }
            let placeholder = f.placeholderAttributedString?.string ?? ""
            check(f.stringValue.isEmpty && placeholder == "Packing list" && rowTitle(noteTab) == "Packing list",
                  "parityp13b title: a note without a title shows its first line, in the field (dimmed) and on its row (\(placeholder), \(rowTitle(noteTab)))")
            let tv = editor(noteTab)!.textView
            check(f.superview === tv && f.frame.width > 200 && f.frame.minY > 0 && f.frame.maxY <= tv.textContainerInset.height,
                  "parityp13b title: the field sits at the top of the note, above the text, and scrolls with it (\(f.frame), text from y \(tv.textContainerInset.height))")
            clickTitle(done)
        }
        run { [self] in check(titleEditing(), "parityp13b title: a click puts the keyboard in the title field (\(Self.describe(c.window.firstResponder)))") }
        run { [self] in typeText("Lisbon trip") }
        wait(0.4)
        run { [self] in
            let n = store().note(noteID)
            check(n?.title == "Lisbon trip" && store().tab(noteTab)?.title == "Lisbon trip" && rowTitle(noteTab) == "Lisbon trip"
                  && c.window.title.hasSuffix("Lisbon trip"),
                  "parityp13b title: typing names the note; its row and the window title follow as it's typed "
                  + "(note \(n?.title ?? "nil"), row \(rowTitle(noteTab)), window \(c.window.title))")
            check(n?.document.title == "Packing list", "parityp13b title: the text is untouched (\(n?.document.title ?? "?"))")
        }
        step { [self] done in p13bShot("p13b-title", done) }
        key("\r", 36)
        wait(0.2)
        run { [self] in check(textHasKeyboard(noteTab) && editor(noteTab)?.textView.selectedRange().location == 0,
                              "parityp13b title: Return hands the keyboard to the text, at its start (\(Self.describe(c.window.firstResponder)))") }
        run { [self] in
            let um = editor(noteTab)?.textView.undoManager
            note("parityp13b: the note's undo before ⌘Z: \(um?.canUndo == true ? "\"\(um?.undoActionName ?? "")\"" : "nothing")")
        }
        menuKey("z")
        wait(0.3)
        run { [self] in
            check(store().note(noteID)?.title == nil && field()?.stringValue == "" && rowTitle(noteTab) == "Packing list",
                  "parityp13b title: ⌘Z in the text takes the title back; the row shows the first line again (title \(store().note(noteID)?.title ?? "nil"), row \(rowTitle(noteTab)))")
            editor(noteTab)?.textView.redo(nil)
            check(store().note(noteID)?.title == "Lisbon trip" && field()?.stringValue == "Lisbon trip" && rowTitle(noteTab) == "Lisbon trip",
                  "parityp13b title: redo puts it back (title \(store().note(noteID)?.title ?? "nil"), row \(rowTitle(noteTab)))")
        }
        // Esc drops what was typed in the field.
        step { done in clickTitle(done) }
        run { [self] in typeText(" in May") }
        wait(0.3)
        run { [self] in check(store().note(noteID)?.title == "Lisbon trip in May", "parityp13b title: typing goes on after the title, where the click put the caret (\(store().note(noteID)?.title ?? "nil"))") }
        key("\u{1b}", 53)
        wait(0.3)
        run { [self] in
            check(store().note(noteID)?.title == "Lisbon trip" && field()?.stringValue == "Lisbon trip" && rowTitle(noteTab) == "Lisbon trip" && textHasKeyboard(noteTab),
                  "parityp13b title: Esc drops what was typed and hands the keyboard to the text (title \(store().note(noteID)?.title ?? "nil"), row \(rowTitle(noteTab)))")
        }
        // Emptied, the first line names the note again; then the title for the rest of the run.
        step { done in clickTitle(done) }
        menuKey("a")
        key("\u{7f}", 51)
        key("\r", 36)
        wait(0.3)
        run { [self] in
            check(store().note(noteID)?.title == nil && rowTitle(noteTab) == "Packing list" && field()?.placeholderAttributedString?.string == "Packing list"
                  && c.window.title.hasSuffix("Packing list"),
                  "parityp13b title: an emptied title falls back to the first line, on the row, in the window title and in the field (row \(rowTitle(noteTab)), window \(c.window.title))")
        }
        step { done in clickTitle(done) }
        run { [self] in typeText("Lisbon trip") }
        key("\r", 36)
        wait(0.3)
        // A rename of a pinned note's row is its title: the field shows it.
        run { [self] in c.show(pinnedNoteTab, focus: true) }
        step { [self] done in waitUntil({ editor(pinnedNoteTab)?.view.window != nil }, timeout: 3) { done() } }
        run { [self] in
            try? store().renameItem(pinnedItem, to: "Renamed on its row")
            let f = editor(pinnedNoteTab)?.view.titleField
            check(f?.stringValue == "Renamed on its row" && store().item(pinnedItem)?.displayTitle == "Renamed on its row" && store().item(pinnedItem)?.title == nil,
                  "parityp13b title: renaming a pinned note's row sets its title; the field shows it (\(f?.stringValue ?? "no field"))")
            check(store().note(noteID)?.title == "Lisbon trip", "parityp13b title: the Today note keeps \"Lisbon trip\" (\(store().note(noteID)?.title ?? "nil"))")
            c.show(pageTab, focus: false)
        }

        // 2. The note's row onto the right half of the page's row: page | note, the editor focused.
        step { [self] done in
            var last: [NSRect] = [], still = 0
            waitUntil({
                guard let p = self.c.pageView(for: sid), let a = self.todayRow(noteTab, in: p), let b = self.todayRow(pageTab, in: p) else { return false }
                let now = [a.convert(a.bounds, to: nil), b.convert(b.bounds, to: nil)]
                still = now == last ? still + 1 : 0
                last = now
                return still >= 3 && self.c.shownTabID == pageTab && self.c.engineTab(for: pageTab)?.isLoading == false
                    && !self.c.animator.isRunning("sidebar")
            }, timeout: 5) { done() }
        }
        step { [self] done in
            guard let p = c.pageView(for: sid), let from = todayRow(noteTab, in: p), let onto = todayRow(pageTab, in: p) else {
                check(false, "parityp13b drag onto a row: both rows show"); return done()
            }
            let start = from.convert(NSPoint(x: 90, y: from.bounds.midY), to: nil)
            let end = onto.convert(NSPoint(x: onto.bounds.width - 40, y: onto.bounds.midY), to: nil)
            dragCase("parityp13b drag onto a row: the note's row on the page row's right half makes page | note, shown, the note's editor in its pane with the keyboard",
                     from: start, to: end, until: {
                         store().split(containing: noteTab)?.tabIDs == [pageTab, noteTab] && self.c.shownTabID == noteTab && inPane(noteTab)
                     }) { self.p13bShot("p13b-note-split-drag") { done() } }
        }

        // 3. Out again, by the pane's handle, onto the end of Today.
        step { [self] done in
            guard let pane = c.splitContainer.pane(for: noteTab) else { check(false, "parityp13b drag out: the note's pane"); return done() }
            pane.handle.setShown(true)
            let h = pane.handle
            let start = h.convert(NSPoint(x: h.grabRect.midX, y: h.grabRect.midY), to: nil)
            guard let end = endOfToday() else { check(false, "parityp13b drag out: the end of Today shows in the sidebar"); return done() }
            let frameView = c.window.contentView?.superview
            let hit = frameView?.hitTest(frameView!.convert(start, from: nil))
            note("parityp13b drag out: press on \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing")")
            dragCase("parityp13b drag out: the note's pane dragged by its handle to the end of Today is a row of its own again, the page alone on screen",
                     from: start, to: end, until: {
                         store().split(containing: noteTab) == nil && store().split(containing: pageTab) == nil && store().tab(noteTab)?.isToday == true
                             && self.c.shownSplitID == nil && self.c.shownTabID == pageTab
                     }, done)
        }

        // 4. The note's row over the page's right edge: page | note again.
        step { [self] done in
            c.show(pageTab, focus: false)
            settled(done)
        }
        step { [self] done in
            guard let p = c.pageView(for: sid), let from = todayRow(noteTab, in: p) else { check(false, "parityp13b drag onto the page: the note's row"); return done() }
            let start = from.convert(NSPoint(x: 90, y: from.bounds.midY), to: nil)
            let card = c.card.frame
            let end = c.root.convert(NSPoint(x: card.maxX - 60, y: card.midY), to: nil)
            dragCase("parityp13b drag onto the page: the note's row dropped on the page's right edge opens it right of the page, the editor focused",
                     from: start, to: end, until: {
                         store().split(containing: pageTab)?.tabIDs == [pageTab, noteTab] && self.c.shownTabID == noteTab && inPane(noteTab)
                             && self.c.splitDropPreview.isHidden
                     }) { self.p13bShot("p13b-note-split-page") { done() } }
        }

        // 5. Pinned and Favorite splits.
        step { [self] done in
            guard let p = c.pageView(for: sid), let from = todayRow(splitNoteTab, in: p),
                  let row = p.list.subviews.compactMap({ $0 as? SplitRowView }).first(where: { $0.splitItem?.id == pinnedSplit }) else {
                check(false, "parityp13b pinned split: the note's row and the pinned split's row"); return done()
            }
            p.list.scrollToVisible(row.frame.insetBy(dx: 0, dy: -8))
            p.layoutSubtreeIfNeeded()
            let start = from.convert(NSPoint(x: 90, y: from.bounds.midY), to: nil)
            let end = row.convert(NSPoint(x: row.bounds.width - 40, y: row.bounds.midY), to: nil)
            dragCase("parityp13b pinned split: a note's row dropped on a pinned split's row joins it as its last pane; the split shows with the note's editor focused",
                     from: start, to: end, until: {
                         let panes = store().panes(ofSplitItem: pinnedSplit)
                         return panes.count == 3 && panes.last.map { NoteURL.isNote($0.savedURL) } == true
                             && NoteURL.isNote(store().tab(self.c.shownTabID)?.url) && self.c.shownSplitID != nil && inPane(self.c.shownTabID ?? "")
                     }) { self.p13bShot("p13b-note-pinned-split") { done() } }
        }
        step { [self] done in
            guard let p = c.pageView(for: sid), let from = todayRow(favoriteNoteTab, in: p),
                  let tile = p.favorites.subviews.compactMap({ $0 as? FavoriteTileView }).first(where: { $0.item?.id == favoriteSplit }) else {
                check(false, "parityp13b Favorite split: the note's row and the Favorite split's tile"); return done()
            }
            let start = from.convert(NSPoint(x: 90, y: from.bounds.midY), to: nil)
            let end = tile.convert(NSPoint(x: tile.bounds.midX + tile.bounds.width / 8, y: tile.bounds.midY), to: nil)
            dragCase("parityp13b Favorite split: a note's row dropped on a Favorite split's tile joins it as its last pane; the split shows with the note's editor focused",
                     from: start, to: end, until: {
                         let panes = store().panes(ofSplitItem: favoriteSplit)
                         return panes.count == 3 && panes.last.map { NoteURL.isNote($0.savedURL) } == true
                             && NoteURL.isNote(store().tab(self.c.shownTabID)?.url) && self.c.shownSplitID != nil && inPane(self.c.shownTabID ?? "")
                     }) { self.p13bShot("p13b-note-favorite-split") { done() } }
        }
        // For the relaunch: the Today split on screen, everything on disk.
        run { [self] in
            c.show(noteTab, focus: true)
            try? store().flush()
            note("parityp13b: written for the relaunch (title \(store().note(noteID)?.title ?? "nil"), split \(store().split(containing: noteTab)?.tabIDs.count ?? 0) panes)")
        }
        wait(0.5)
    }

    /// The window as the window server shows it (a note's editor draws there; buildmac's offscreen captures of notes
    /// come out blank, artifacts/buildmac-setup), then the usual offscreen capture.
    func p13bShot(_ name: String, _ done: @escaping () -> Void) {
        captureOwnWindow(c.window, name: name + "-window")
        captureNow(name, done)
    }

    private func parityP13bRelaunch() {
        let store = c.store
        let sid = store.selectedSpace.id
        func editor(_ tab: String) -> NoteEditor? { NoteURL.noteID(store.tab(tab)?.url).flatMap { NoteCenter.shared.existingEditor($0) } }
        let note = store.state.notes.values.first { $0.title == "Lisbon trip" }
        let tab = note.flatMap { n in store.state.tabs.values.first { $0.url == n.url } }
        // The Command Bar was over this split in every relaunch capture (the parked spare bar, back on screen: polish4).
        checkNoCommandBarAfterRelaunch("parityp13b-relaunch")   // RelaunchCommandBarCheck.swift
        run { [self] in
            check(note != nil && note?.document.title == "Packing list" && tab?.title == "Lisbon trip",
                  "parityp13b-relaunch: the note's title is back, its first line untouched, its row named by it (\(tab?.title ?? "no tab"))")
            check(store.state.notes.values.contains { $0.title == "Renamed on its row" }, "parityp13b-relaunch: the pinned note's title from its row is back")
            let x = tab.flatMap { store.split(containing: $0.id) }
            check(x?.itemID == nil && x?.tabIDs.count == 2 && x.map { store.members(of: $0).map(\.title) } == ["Trip page", "Lisbon trip"],
                  "parityp13b-relaunch: the Today split page | note is back (\(x.map { store.members(of: $0).map(\.title) } ?? []))")
            let pinned = store.pinnedRoots(ofSpace: sid).first { $0.kind == .split }
            let pid = store.profile(ofSpace: sid).id
            let fav = store.favorites(ofProfile: pid).first { $0.kind == .split }
            for (what, item) in [("pinned", pinned), ("Favorite", fav)] {
                let panes = item.map { store.panes(ofSplitItem: $0.id) } ?? []
                check(panes.count == 3 && panes.contains { NoteURL.isNote($0.savedURL) },
                      "parityp13b-relaunch: the \(what) split keeps its note pane (\(panes.map(\.displayTitle)))")
            }
            if let tab { c.show(tab.id, focus: true) }
        }
        step { [self] done in
            waitUntil({ tab.map { t in editor(t.id).map { $0.view.superview === self.c.splitContainer.pane(for: t.id)?.host } ?? false } ?? false }, timeout: 5) { done() }
        }
        run { [self] in
            guard let tab, let e = editor(tab.id) else { return check(false, "parityp13b-relaunch: the note's editor") }
            check(c.shownSplitID != nil && e.view.superview === c.splitContainer.pane(for: tab.id)?.host && e.view.titleField.stringValue == "Lisbon trip"
                  && c.window.firstResponder === e.textView,
                  "parityp13b-relaunch: showing the note opens its split, its editor in the pane with the title in its field and the keyboard")
        }
        step { [self] done in p13bShot("p13b-relaunch", done) }
    }
}
#endif
