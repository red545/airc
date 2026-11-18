// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

// Notes in the browser window (docs/user/notes.md). A note's tab has no engine page: WindowController.show puts its
// editor in the page card instead (above the card's edge, as the "Open in another window" card is). One editor per note
// for the whole app, so a note shown in another window moves there with its text and its undo history.

/// One note's editor: its view, its own undo history, and its text and title going into the store as they're typed
/// (in memory at once, on disk with the store's next flush: ⌘W right after a keystroke never loses it).
final class NoteEditor: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    let noteID: String
    let view: NoteEditorView
    private let history = UndoManager()
    private weak var store: SpacesStore?
    /// The window whose card shows it.
    weak var controller: WindowController?
    private var lastTitle: String
    /// What this editor last read or wrote: anything else in the store (a backup restored, ⌘Z of a delete) is newer.
    private var known: NoteDocument
    /// The store's text when this editor last read or wrote it: a store change to anything else came from elsewhere.
    private var lastStored: NoteDocument?
    /// The title when the title field took the keyboard: leaving it makes the change one undo step.
    private var titleBefore: String?
    private var storeToken: Int?

    init(noteID: String, store: SpacesStore, style: NoteStyle) {
        self.noteID = noteID
        self.store = store
        view = NoteEditorView(noteID: noteID, style: style)
        let note = store.note(noteID)
        known = note?.document ?? NoteDocument()
        lastStored = note?.document
        lastTitle = note?.displayTitle ?? NoteURL.untitled
        super.init()
        view.textView.delegate = self
        view.textView.load(known)
        known = view.textView.document
        view.textView.onChange = { [weak self] in self?.save() }
        // P13b: the title field. A pinned row named before notes had titles gives the note that name first.
        view.titleField.delegate = self
        view.textView.onMoveAboveText = { [weak self] in self?.focusTitle() }
        if store.adoptNoteRowName(noteID) { lastTitle = store.note(noteID)?.displayTitle ?? lastTitle }
        showTitle()
        storeToken = store.observe { [weak self] change in
            guard let self, change.refs.contains(where: { $0.kind == .note && $0.id == self.noteID }) else { return }
            self.showTitle()
            // Text from elsewhere (iCloud sync from another Mac): shown at once, so the next keystroke builds on it.
            // This editor's own typing and a title change leave the stored text as it last saw it.
            if self.store?.note(self.noteID)?.document != self.lastStored { self.reloadIfChanged() }
        }
    }

    deinit { if let storeToken { store?.removeObserver(storeToken) } }

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
        lastStored = doc
        store.updateNote(noteID, document: doc)
        titleMayHaveChanged()
    }

    /// The rows and the window title follow a new name (a title typed, or the first line while there's none).
    private func titleMayHaveChanged() {
        let title = store?.note(noteID)?.displayTitle ?? NoteURL.untitled
        if title != lastTitle {
            lastTitle = title
            controller?.noteTitleChanged(noteID)
        }
    }

    // MARK: The title field (P13b)

    /// The store's title in the field (unless it's being typed there), and the first line as its placeholder.
    func showTitle() {
        guard let n = store?.note(noteID) else { return }
        let field = view.titleField
        if field.currentEditor() == nil, field.stringValue != (n.title ?? "") { field.stringValue = n.title ?? "" }
        view.titlePlaceholder = n.document.title
    }

    func focusTitle() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view.titleField)
        view.titleField.currentEditor()?.selectedRange = NSRange(location: (view.titleField.stringValue as NSString).length, length: 0)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        titleBefore = store?.note(noteID)?.title
    }

    func controlTextDidChange(_ obj: Notification) {
        try? store?.setNoteTitle(noteID, view.titleField.stringValue, deferred: true)
        titleMayHaveChanged()
    }

    /// Leaving the field: what was typed in it is one step of the note's own undo history (⌘Z in the text takes the
    /// title back, as Arc's did), and the field shows the title as kept (one line, trimmed).
    func controlTextDidEndEditing(_ obj: Notification) {
        let before = titleBefore, after = store?.note(noteID)?.title
        titleBefore = nil
        // The field's own typing steps were in this history (its editor's undo manager is the text view's, up the
        // responder chain); they go with the editing, and the change becomes one step.
        if let fieldEditor = obj.userInfo?["NSFieldEditor"] as? NSTextView {
            history.removeAllActions(withTarget: fieldEditor)
            if let storage = fieldEditor.textStorage { history.removeAllActions(withTarget: storage) }
        }
        view.titleField.stringValue = after ?? ""
        if before != after { registerTitleUndo(back: before, from: after) }
        if let movement = obj.userInfo?["NSTextMovement"] as? Int,
           [NSTextMovement.return.rawValue, NSTextMovement.tab.rawValue, NSTextMovement.down.rawValue].contains(movement) {
            focusText(atStart: true)
        }
    }

    /// Esc in the field: the title it had before, and the keyboard back in the text. ↓: the text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            textView.string = titleBefore ?? ""
            try? store?.setNoteTitle(noteID, titleBefore, deferred: true)
            titleMayHaveChanged()
            focusText(atStart: true)
            return true
        case #selector(NSResponder.moveDown(_:)):
            focusText(atStart: true)
            return true
        default:
            return false
        }
    }

    private func focusText(atStart: Bool) {
        guard let window = view.window else { return }
        window.makeFirstResponder(textView)
        if atStart { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
    }

    /// Sets the title as an undo or redo of the field's change, registering the way back.
    private func registerTitleUndo(back old: String?, from new: String?) {
        history.registerUndo(withTarget: self) { e in
            try? e.store?.setNoteTitle(e.noteID, old, deferred: true)
            e.showTitleNow()
            e.titleMayHaveChanged()
            e.registerTitleUndo(back: new, from: old)
        }
        history.setActionName("Title")
    }

    /// The field shows the store's title even while it has the keyboard (an undo from the menu).
    private func showTitleNow() {
        let t = store?.note(noteID)?.title ?? ""
        if let editor = view.titleField.currentEditor() { editor.string = t }
        view.titleField.stringValue = t
        showTitle()
    }

    /// The store's text when it changed elsewhere since this editor last saw it.
    func reloadIfChanged() {
        guard let store else { return }
        lastStored = store.note(noteID)?.document
        let stored = lastStored ?? NoteDocument()
        guard stored != known else { return }
        known = stored
        lastTitle = store.note(noteID)?.displayTitle ?? NoteURL.untitled
        let selection = textView.selectedRange()
        textView.load(stored)
        known = textView.document
        // The caret stays about where it was (clamped to the new text).
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        history.removeAllActions()
        showTitle()
        controller?.noteTitleChanged(noteID)
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

    /// Pictures another Mac's note brought (iCloud sync): the open notes draw them instead of their placeholders.
    func picturesArrived() {
        for e in editors.values { e.textView.needsDisplay = true }
    }

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

/// What takes a page's place in the card: a note's editor (here) or an Easel's (P19a, Easels/EaselEditor.swift). Neither
/// ever gets an engine page.
protocol CardDocument: AnyObject {
    var cardView: NSView { get }
    func focus()
    /// Before it goes into `c`'s card: its window, its colours, the store's latest.
    func prepare(for c: WindowController)
}

extension NoteEditor: CardDocument {
    var cardView: NSView { view }

    func prepare(for c: WindowController) {
        controller = c
        reloadIfChanged()
        view.style = NoteStyle(c.currentPalette.resolved)
        view.cornerRadius = c.card.cornerRadius
    }
}

extension WindowController {
    /// The editor for `tabID`'s note or Easel; nil when it's a page's tab.
    func noteEditor(forTab tabID: String) -> CardDocument? {
        let url = store.tab(tabID)?.url
        if let id = NoteURL.noteID(url) { return NoteCenter.shared.editor(for: id, store: store, style: NoteStyle(currentPalette.resolved)) }
        if let id = EaselURL.easelID(url) { return EaselCenter.shared.editor(for: id, store: store) }
        // whatsnew2: the What's new tab's native page (Browser/WhatsNewPage.swift).
        if WhatsNewURL.isPage(url) { return WhatsNewPage.page(forTab: tabID, store: store, theme: currentPalette.resolved) }
        // agentux: the All tasks tab (Agent/Pane/AgentTasksPage.swift).
        if AgentTasksURL.isPage(url) { return AgentTasksPage.page(forTab: tabID, store: store, theme: currentPalette.resolved) }
        return nil
    }

    /// Puts `editor` in the page card, over the card's edge (it leaves another window's card, which says "Open in
    /// another window" then).
    func present(_ editor: CardDocument) {
        hideNote(except: editor)
        editor.prepare(for: self)
        let v = editor.cardView
        if v.superview !== card {
            v.frame = card.bounds
            v.autoresizingMask = [.width, .height]
            card.addSubview(v)
        }
        v.isHidden = false
    }

    /// The card shows a page, a split, nothing, or another window's tab: no note or Easel in it.
    func hideNote(except keep: CardDocument? = nil) {
        for v in card.subviews where (v is NoteEditorView || v is EaselEditorView || v is WhatsNewPageView || v is AgentTasksPageView) && v !== keep?.cardView {
            if let r = v.window?.firstResponder as? NSView, r === v || r.isDescendant(of: v) { window.makeFirstResponder(nil) }
            v.removeFromSuperview()
        }
        NoteCenter.shared.dropClosed(store: store)
        EaselCenter.shared.dropClosed(store: store)
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
        if let page = WhatsNewPage.existing(shownTabID), page.host.superview === card { page.prepare(for: self) }
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

    /// A note row's menu: what makes sense for a note (no links or Favorites; splits by drag and ⌥-click, P13b).
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
            // P13b: the note's title, as its title field (Notes.swift renameNoteRow).
            m.add("Rename…") { [weak self] in self?.renameItemFromMenu(item.id) }
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
