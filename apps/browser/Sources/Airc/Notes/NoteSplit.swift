// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

// Arc's "New Note (in Split)": "Creates a new Note beside your current page" (docs/user/notes.md). The note is a pane
// of a Today split: its editor goes in the pane's host where a page's view would, the page beside it stays as it was,
// and the note has the keyboard. WindowController's showSplit, focusSplitPane and leaveSplitPresentation ask here for a
// pane's note (`notePane(for:)`); the panes, dividers and handles are Split View's own (Browser/SplitView.swift).
// Notes are never panes of pinned or Favorite splits, and drags don't make splits of notes (AircKit's canBeTodayPane).

extension WindowController {
    /// The editor of `tabID` when it's a note: its pane shows the editor, not a page.
    func notePane(for tabID: String) -> NoteEditor? { noteEditor(forTab: tabID) }

    /// Puts the notes among `ids` in their panes' hosts (taking each from wherever it was: one editor per note).
    func presentNotePanes(_ ids: [String]) {
        for id in ids {
            guard let note = notePane(for: id), let host = splitContainer.pane(for: id)?.host else { continue }
            note.controller = self
            note.reloadIfChanged()
            note.view.style = NoteStyle(currentPalette.resolved)
            note.view.cornerRadius = 0   // the pane rounds its own corners
            if note.view.superview !== host {
                note.view.frame = host.bounds
                note.view.autoresizingMask = [.width, .height]
                host.addSubview(note.view)
            }
            note.view.isHidden = false
        }
    }

    /// The split leaves the window (a page alone, nothing, another Space): its notes leave their panes.
    func releaseNotePanes() {
        for v in notePaneViews {
            if v.window?.firstResponder === v.textView { window.makeFirstResponder(nil) }
            v.removeFromSuperview()
        }
        NoteCenter.shared.dropClosed(store: store)
    }

    /// The note editors in the split on screen.
    var notePaneViews: [NoteEditorView] {
        guard shownSplitID != nil, !splitContainer.isHidden else { return [] }
        return splitContainer.tabIDs.flatMap { id in (splitContainer.pane(for: id)?.host.subviews ?? []).compactMap { $0 as? NoteEditorView } }
    }

    /// Whether New Note in Split can put a note beside what's on screen: a page or a Today split with room, not a
    /// pinned or Favorite split.
    var canAddNoteInSplit: Bool {
        guard let anchor = shownTabID, store.tab(anchor) != nil, multiWindow.elsewhereTabID == nil else { return false }
        if let x = store.split(containing: anchor) { return x.itemID == nil && x.tabIDs.count < Split.maxPanes }
        return !store.isNoteTab(anchor)
    }

    /// Arc's New Note (in Split): a new Today note (or the chosen app's new document) as a pane beside the page on
    /// screen, focused, the page kept as it was. In a Today split, one more pane after the focused one.
    func newNoteInSplit(source: TelemetryFeature.NoteSource) {
        closeCommandBar()
        guard let anchor = shownTabID, store.tab(anchor) != nil else { return NSSound.beep() }
        let x = store.split(containing: anchor)
        if let x, x.itemID != nil { return showToast("A note can’t be in a pinned or Favorite split") }
        if let x, x.tabIDs.count >= Split.maxPanes { return showToast(Self.splitFullMessage) }
        guard canAddNoteInSplit else { return NSSound.beep() }
        let chosen = NoteApps.chosen(app)
        let id: String
        switch chosen.route(online: NoteApps.isOnline()) {
        case .open(let url):
            guard let t = NoteApps.openTab(self, url) else { return NSSound.beep() }
            id = t
        case .note(let fallback):
            let first = NoteDocument(blocks: [NoteBlock(kind: .heading1)])
            guard let t = try? store.createNote(inSpace: currentSpaceID, pinned: false, document: first) else { return NSSound.beep() }
            Telemetry.shared.record(.featureUsed(.noteCreate(source)))
            id = t.id
            if fallback { showToast("You’re offline, so this is an Airc note, not a \(chosen.documentName)") }
        }
        addPane(id, nextTo: anchor, axis: x?.axis ?? .horizontal)
    }
}
