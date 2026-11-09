// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

// Notes in the browser window (docs/user/notes.md). A note's tab has no engine page: WindowController.show puts its
// editor in the page card instead (above the card's edge, as the "Open in another window" card is). One editor per note
// for the whole app, so a note shown in another window moves there with its text and its undo history.

/// One note's editor: its view, its own undo history, and its text going into the store as it's typed (in memory at
/// once, on disk with the store's next flush: ⌘W right after a keystroke never loses it).
final class NoteEditor: NSObject, NSTextViewDelegate {
    let noteID: String
    let view: NoteEditorView
    private let history = UndoManager()
    private weak var store: SpacesStore?
    /// The window whose card shows it.
    weak var controller: WindowController?
    private var lastTitle: String
    /// What this editor last read or wrote: anything else in the store (a backup restored, ⌘Z of a delete) is newer.
    private var known: NoteDocument

    init(noteID: String, store: SpacesStore, style: NoteStyle) {
        self.noteID = noteID
        self.store = store
        view = NoteEditorView(noteID: noteID, style: style)
        let note = store.note(noteID)
        known = note?.document ?? NoteDocument()
        lastTitle = note?.displayTitle ?? NoteURL.untitled
        super.init()
        view.textView.delegate = self
        view.textView.load(known)
        known = view.textView.document
        view.textView.onChange = { [weak self] in self?.save() }
    }

    var textView: NoteTextView { view.textView }

    func undoManager(for view: NSTextView) -> UndoManager? { history }

    func textDidChange(_ notification: Notification) { save() }

    /// A click on a link: a new tab in the note's Space (Arc's notes opened links beside the note).
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let c = controller {
            c.navigate(to: url, newTab: true)
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    func save() {
        guard let store, store.note(noteID) != nil || store.referencedNoteIDs.contains(noteID) else { return }
        let doc = textView.document
        guard doc != known else { return }
        known = doc
        store.updateNote(noteID, document: doc)
        let title = store.note(noteID)?.displayTitle ?? NoteURL.untitled
        if title != lastTitle {
            lastTitle = title
            controller?.noteTitleChanged(noteID)
        }
    }

    /// The store's text when it changed elsewhere since this editor last saw it.
    func reloadIfChanged() {
        guard let store else { return }
        let stored = store.note(noteID)?.document ?? NoteDocument()
        guard stored != known else { return }
        known = stored
        lastTitle = store.note(noteID)?.displayTitle ?? NoteURL.untitled
        textView.load(stored)
        known = textView.document
        history.removeAllActions()
    }

    func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(textView)
    }
}

final class NoteCenter {
    static let shared = NoteCenter()
    private var editors: [String: NoteEditor] = [:]

    func editor(for noteID: String, store: SpacesStore, style: NoteStyle) -> NoteEditor {
        if let e = editors[noteID] { return e }
        let e = NoteEditor(noteID: noteID, store: store, style: style)
        editors[noteID] = e
        return e
    }

    func existingEditor(_ noteID: String) -> NoteEditor? { editors[noteID] }

    /// Editors of notes no tab has open any more (closed, archived, deleted) and no card shows. Their text is already
    /// in the store (every change is).
    func dropClosed(store: SpacesStore) {
        let open = Set(store.state.tabs.values.compactMap { NoteURL.noteID($0.url) })
        for (id, e) in editors where !open.contains(id) && e.view.superview == nil { editors[id] = nil }
    }

    /// Launch: notes no row points at go, then pictures no note shows (unless a backup still names them).
    static func collectGarbage(store: SpacesStore, backups: URL) {
        _ = try? store.removeOrphanNotes()
        NoteImages.collectGarbage(keeping: store.noteImageFiles, backups: backups)
    }
}

extension WindowController {
    /// The editor for `tabID`'s note; nil when it isn't a note's tab.
    func noteEditor(forTab tabID: String) -> NoteEditor? {
        guard let id = NoteURL.noteID(store.tab(tabID)?.url) else { return nil }
        return NoteCenter.shared.editor(for: id, store: store, style: NoteStyle(currentPalette.resolved))
    }

    /// Puts `editor` in the page card, over the card's edge (it leaves another window's card, which says "Open in
    /// another window" then).
    func present(_ editor: NoteEditor) {
        hideNote(except: editor)
        editor.controller = self
        editor.reloadIfChanged()
        editor.view.style = NoteStyle(currentPalette.resolved)
        editor.view.cornerRadius = card.cornerRadius
        if editor.view.superview !== card {
            editor.view.frame = card.bounds
            editor.view.autoresizingMask = [.width, .height]
            card.addSubview(editor.view)
        }
        editor.view.isHidden = false
    }

    /// The card shows a page, a split, nothing, or another window's tab: no note in it.
    func hideNote(except keep: NoteEditor? = nil) {
        for v in card.subviews.compactMap({ $0 as? NoteEditorView }) where v !== keep?.view {
            if v.window?.firstResponder === v.textView { window.makeFirstResponder(nil) }
            v.removeFromSuperview()
        }
        NoteCenter.shared.dropClosed(store: store)
    }

    /// The note on screen with the keyboard's tab: in the card, or a split's focused pane (Notes/NoteSplit.swift).
    var shownNote: NoteEditor? {
        guard multiWindow.elsewhereTabID == nil, let id = NoteURL.noteID(store.tab(shownTabID)?.url),
              card.subviews.contains(where: { ($0 as? NoteEditorView)?.noteID == id }) || notePaneViews.contains(where: { $0.noteID == id })
        else { return nil }
        return NoteCenter.shared.existingEditor(id)
    }

    /// The Space's colours changed (a switch, a theme edit, dark mode).
    func noteChromeChanged() {
        let s = NoteStyle(currentPalette.resolved)
        for v in notePaneViews where v.style != s { v.style = s }
        guard let note = shownNote else { return }
        // A backup restored or ⌘Z of a delete since: the store's text, not the editor's older copy.
        note.reloadIfChanged()
        if note.view.style != s { note.view.style = s }
        if note.view.superview === card { note.view.cornerRadius = card.cornerRadius }
    }

    /// Arc's New Note: ⌃⇧N, the Command Bar, the sidebar's "+". An Airc note, or a new document of the app chosen in
    /// Settings → General → Notes (Arc's later "New Note opens your default notes app"); offline, an Airc note, and
    /// the window says why. Private and Little Arc windows don't have it (their menus and keys don't reach here).
    func newNote(source: TelemetryFeature.NoteSource) {
        let chosen = NoteApps.chosen(app)
        switch chosen.route(online: NoteApps.isOnline()) {
        case .open(let url):
            closeCommandBar()
            NoteApps.open(self, url)
        case .note(let fallback):
            newAircNote(source: source)
            if fallback { showToast("You’re offline, so this is an Airc note, not a \(chosen.documentName)") }
        }
    }

    /// Always Airc's own note: pinned in the current Space, shown, ready to type its title.
    func newAircNote(source: TelemetryFeature.NoteSource) {
        closeCommandBar()
        let first = NoteDocument(blocks: [NoteBlock(kind: .heading1)])
        guard let t = try? store.createNote(inSpace: currentSpaceID, document: first) else { return NSSound.beep() }
        Telemetry.shared.record(.featureUsed(.noteCreate(source)))
        show(t.id)
    }

    /// A note's first line changed: its rows and the window title follow.
    func noteTitleChanged(_ noteID: String) {
        let url = NoteURL.make(noteID)
        for t in store.state.tabs.values where t.url == url { refreshRow(t.id) }
        updateWindowTitle()
        scheduleSpareBarRefresh()
    }

    /// ⌘P in a note: Print, with Save as PDF in the panel. True when a note took it.
    func printNote() -> Bool {
        guard let note = shownNote else { return false }
        note.view.printNote(from: window, title: store.note(note.noteID)?.displayTitle ?? NoteURL.untitled)
        return true
    }

    /// ⇧⌘C and the other address commands on a note: a note has no address to copy.
    func noteHasNoLink() -> Bool {
        guard store.isNoteTab(shownTabID) else { return false }
        showToast("A note has no link to copy")
        return true
    }

    /// A note row's menu: what makes sense for a note (no links, Favorites or splits).
    func noteMenu(for entry: SidebarEntry) -> NSMenu? {
        let m = NSMenu()
        switch entry {
        case .today(let t) where NoteURL.isNote(t.url):
            m.add("Pin Note", "⌘D") { [weak self] in
                guard let self else { return }
                try? self.store.togglePin(t.id, inSpace: self.currentSpaceID)
            }
            m.add("Duplicate") { [weak self] in _ = try? self?.store.duplicateTab(t.id) }
            let move = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for s in store.orderedSpaces where s.id != t.spaceID {
                sub.add(s.iconLabel + "  " + s.name) { [weak self] in self?.moveTab(t.id, to: s.id) }
            }
            move.submenu = sub
            move.isEnabled = !sub.items.isEmpty
            m.addItem(move)
            if let id = NoteURL.noteID(t.url) { m.add("Export Note…") { [weak self] in self?.exportNote(id) } }
            m.addItem(.separator())
            m.add("Archive Note", "⌘W") { [weak self] in self?.closeTab(t.id) }
        case .pinned(let item, _, let t) where NoteURL.isNote(item.savedURL):
            m.add("Duplicate") { [weak self] in _ = try? self?.store.duplicateItem(item.id) }
            if let id = NoteURL.noteID(item.savedURL) { m.add("Export Note…") { [weak self] in self?.exportNote(id) } }
            m.addItem(.separator())
            m.add("Unpin") { [weak self] in
                guard let self else { return }
                self.performDrop(.item(item.id), to: .today(spaceID: self.currentSpaceID, index: 0))
            }
            if let t { m.add("Close (keeps it pinned)") { [weak self] in self?.closeTab(t.id) } }
            m.add("Delete Note") { [weak self] in
                guard let self else { return }
                if let t { self.forgetPage(t.id, close: true) }
                try? self.store.deleteItem(item.id)
            }
        default:
            return nil
        }
        return m
    }
}
