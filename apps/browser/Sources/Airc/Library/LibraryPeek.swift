// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

// L05: Library › Notes and Library › Easels open a note or an Easel in Peek over the current page, as Arc's Library did
// (its peeked-item kinds are Easels and documents). A note or an Easel has no engine page, so this isn't Peek.swift's
// page Peek: the same card (PeekOverlayView) holds the document's own editor, editable as in its tab. The expand
// button is Open in Space (⌘O): the Peek closes and the document opens where its row is (LibraryNotes/LibraryEasels
// `open`). ✕, Esc, ⌘W, a click outside, another tab or Space close it. One editor per document for the whole app, so a
// document already on screen elsewhere (another window's card, a split) isn't taken from there: it opens in its Space.

final class DocumentPeek {
    enum Kind: Equatable {
        case note(String)
        case easel(String)
    }

    /// One per window.
    private(set) static var active: [ObjectIdentifier: DocumentPeek] = [:]

    let kind: Kind
    let editor: CardDocument
    let view: PeekOverlayView
    private weak var controller: WindowController?
    private let shownAtOpen: String?
    private let spaceAtOpen: String
    private var frameToken: NSObjectProtocol?
    private var storeToken: Int?
    private var keyMonitor: Any?
    private(set) var closed = false

    private init(kind: Kind, editor: CardDocument, controller c: WindowController) {
        self.kind = kind
        self.editor = editor
        controller = c
        shownAtOpen = c.shownTabID
        spaceAtOpen = c.currentSpaceID
        view = PeekOverlayView(palette: c.currentPalette)
    }

    var title: String {
        switch kind {
        case .note(let id): controller?.store.note(id)?.displayTitle ?? NoteURL.untitled
        case .easel: (editor as? EaselEditor)?.document.displayTitle ?? EaselURL.untitled
        }
    }

    // MARK: Open

    /// Opens `kind` in a Peek over `c`'s page. False when it can't be peeked (gone, or on screen elsewhere): the caller
    /// opens it in its Space instead.
    @discardableResult
    static func open(_ kind: Kind, in c: WindowController) -> Bool {
        let editor: CardDocument
        switch kind {
        case .note(let id):
            guard c.store.note(id) != nil else { return false }
            editor = NoteCenter.shared.editor(for: id, store: c.store, style: NoteStyle(c.currentPalette.resolved))
        case .easel(let id):
            guard EaselCenter.shared.files.exists(id) else { return false }
            editor = EaselCenter.shared.editor(for: id, store: c.store)
        }
        // Already in a card or a split: it stays there.
        if editor.cardView.superview != nil, active[ObjectIdentifier(c)]?.editor !== editor { return false }
        active[ObjectIdentifier(c)]?.close(animated: false)
        if c.peek != nil { c.closePeek() }
        let p = DocumentPeek(kind: kind, editor: editor, controller: c)
        active[ObjectIdentifier(c)] = p
        p.present()
        return true
    }

    private func present() {
        guard let c = controller else { return }
        c.root.addSubview(view, positioned: .below, relativeTo: c.toast)
        view.layoutIn(page: c.card.frame)
        editor.prepare(for: c)
        let v = editor.cardView
        v.frame = view.pageHost.bounds
        v.autoresizingMask = [.width, .height]
        view.pageHost.addSubview(v)
        v.isHidden = false
        view.splitButton.isHidden = true
        view.expandButton.toolTip = "Open in Space (⌘O)"
        view.expandButton.setAccessibilityLabel("Open in Space")
        view.closeButton.setAccessibilityLabel("Close")
        view.titleLabel.stringValue = title
        view.setAccessibilityIdentifier("documentPeek")
        view.onClose = { [weak self] in self?.close() }
        view.onPromote = { [weak self] in self?.openInSpace() }
        // The card follows the window (resizes, the sidebar showing or hiding).
        c.card.postsFrameChangedNotifications = true
        frameToken = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: c.card, queue: .main) { [weak self] _ in
            guard let self, let c = self.controller else { return }
            self.view.layoutIn(page: c.card.frame)
        }
        // Another tab or Space shown, or the document gone: the Peek closes. Its title follows the document's.
        storeToken = c.store.observe { [weak self] _ in
            guard let self, !self.closed, let c = self.controller else { return }
            if c.shownTabID != self.shownAtOpen || c.currentSpaceID != self.spaceAtOpen || !self.exists {
                DispatchQueue.main.async { self.close() }
                return
            }
            self.view.titleLabel.stringValue = self.title
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, !self.closed, let w = self.controller?.window, e.window === w, w.attachedSheet == nil else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            switch (e.keyCode, mods) {
            case (53, []):
                // Esc: an Easel's selection goes first (as in its tab); then the Peek.
                if let easel = self.editor as? EaselEditor, !easel.selection.isEmpty { return e }
                self.close()
                return nil
            case (_, .command) where e.charactersIgnoringModifiers == "w":
                self.close()
                return nil
            case (_, .command) where e.charactersIgnoringModifiers == "o":
                self.openInSpace()
                return nil
            default:
                return e
            }
        }
        view.present()
        DispatchQueue.main.async { [weak self] in self?.editor.focus() }
    }

    private var exists: Bool {
        switch kind {
        case .note(let id): controller?.store.note(id) != nil
        case .easel(let id): EaselCenter.shared.existingEditor(id) === editor as AnyObject
        }
    }

    // MARK: Close

    func close(animated: Bool = true) {
        guard !closed else { return }
        closed = true
        let c = controller
        if let c, DocumentPeek.active[ObjectIdentifier(c)] === self { DocumentPeek.active[ObjectIdentifier(c)] = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let frameToken { NotificationCenter.default.removeObserver(frameToken) }
        frameToken = nil
        if let storeToken { c?.store.removeObserver(storeToken) }
        storeToken = nil
        view.onClose = nil
        view.onPromote = nil
        let v = editor.cardView
        if let r = v.window?.firstResponder as? NSView, r === v || r.isDescendant(of: v) { v.window?.makeFirstResponder(nil) }
        if v.superview === view.pageHost { v.removeFromSuperview() }
        (editor as? EaselEditor)?.saveNow(wait: false)
        let overlay = view
        if animated {
            overlay.layer?.fade(from: 1, to: 0, duration: 0.12)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { overlay.removeFromSuperview() }
        } else {
            overlay.removeFromSuperview()
        }
        guard let c else { return }
        NoteCenter.shared.dropClosed(store: c.store)
        EaselCenter.shared.dropClosed(store: c.store)
        if let id = c.shownTabID { c.engineTab(for: id)?.focus() }
    }

    /// The expand button and ⌘O: the document where its row is (switching Space, restoring it from the Archive, or a
    /// Today tab when no row shows it).
    func openInSpace() {
        guard !closed, let c = controller else { return }
        close(animated: false)
        switch kind {
        case .note(let id):
            if let n = c.store.note(id) { LibraryNotes.open(n, in: c) }
        case .easel(let id):
            LibraryEasels.open(id: id, title: (editor as? EaselEditor)?.document.title ?? "", in: c)
        }
    }
}

extension WindowController {
    /// The note or Easel in a Peek over this window's page, if one is.
    var documentPeek: DocumentPeek? { DocumentPeek.active[ObjectIdentifier(self)] }
}
