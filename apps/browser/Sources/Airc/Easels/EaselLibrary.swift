// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Library › Easels (L05; Arc's Library had "Easels & Notes", later "Easels"): every Easel on this Mac in one list,
/// newest edit first, so one can be found and opened wherever its row is: in another Space, a closed folder, archived,
/// or nowhere any more. The search matches titles and the text on them. Archive puts an open Easel's tab in the
/// Archive; Open on an archived one restores it.
enum LibraryEasels {
    struct Entry: Identifiable, Equatable {
        let summary: EaselFiles.Summary
        let place: LibraryNotes.Place
        var id: String { summary.id }
    }

    static func place(of id: String, in store: SpacesStore) -> LibraryNotes.Place {
        let url = EaselURL.make(id)
        if let t = store.state.tabs.values.filter({ $0.url == url }).max(by: { $0.lastActiveAt < $1.lastActiveAt }), let sid = t.spaceID {
            return .tab(id: t.id, spaceID: sid)
        }
        if let i = store.state.items.values.first(where: { $0.savedURL == url }), case .pinned(let sid) = i.container {
            return .pinned(itemID: i.id, spaceID: sid)
        }
        if let e = store.archiveEntries(ofEasel: id).first { return .archived(entryID: e.id) }
        return .none
    }

    static func entries(_ list: [EaselFiles.Summary], store: SpacesStore, query: String = "") -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return list
            .filter { s in q.isEmpty || CommandSearch.score(q, in: s.displayTitle) != nil || s.text.localizedCaseInsensitiveContains(q) }
            .map { Entry(summary: $0, place: place(of: $0.id, in: store)) }
    }

    /// Opens the Easel where its row is, restores it from the Archive, or gives it a Today tab in the current Space.
    @discardableResult
    static func open(_ s: EaselFiles.Summary, in c: WindowController) -> Bool { open(id: s.id, title: s.title, in: c) }

    @discardableResult
    static func open(id: String, title: String, in c: WindowController) -> Bool {
        let store = c.store
        var tabID: String?
        switch place(of: id, in: store) {
        case .tab(let id, let sid):
            if sid != c.currentSpaceID { c.switchToSpace(sid, animated: true) }
            tabID = id
        case .pinned(let itemID, let sid):
            if sid != c.currentSpaceID { c.switchToSpace(sid, animated: true) }
            tabID = (try? store.openItem(itemID, inSpace: sid))?.id
        case .archived(let entryID):
            guard let t = try? store.restoreArchived(entryID, fallbackSpaceID: c.currentSpaceID) else { return false }
            if let sid = t.spaceID, sid != c.currentSpaceID { c.switchToSpace(sid, animated: true) }
            tabID = t.id
        case .none:
            tabID = (try? store.reopenEasel(id, title: title, inSpace: c.currentSpaceID))?.id
        }
        guard let id = tabID else { return false }
        c.reloadAll(animated: false)
        c.show(id)
        c.revealTabInSidebar()
        return true
    }

    /// Archive: an open Easel's Today tabs go to the Archive (a pinned one stays pinned: unpin it in the sidebar).
    @discardableResult
    static func archive(_ s: EaselFiles.Summary, in c: WindowController) -> Bool {
        let tabs = c.store.tabs(showingEasel: s.id).filter { $0.itemID == nil }
        guard !tabs.isEmpty else { return false }
        EaselCenter.shared.existingEditor(s.id)?.saveNow(wait: true)
        for t in tabs { c.closeTab(t.id) }
        return true
    }

    /// P19c: Export… and Share Link… from the Library: the Easel opens (as Open does), then its sheet.
    @discardableResult
    static func export(_ s: EaselFiles.Summary, in c: WindowController, link: Bool) -> Bool {
        guard s.blockCount > 0, open(s, in: c) else { return false }
        DispatchQueue.main.async { [weak c] in
            guard let e = c?.shownEasel, e.easelID == s.id else { return NSSound.beep() }
            if link { e.shareLink() } else { e.export() }
        }
        return true
    }

    /// L05: in a Peek over the current page (Library/LibraryPeek.swift), as Arc's Library peeked Easels. False when it's
    /// on screen elsewhere (the caller opens it in its Space).
    @discardableResult
    static func peek(_ s: EaselFiles.Summary, in c: WindowController) -> Bool {
        if c.shownEasel?.easelID == s.id { return false }
        return DocumentPeek.open(.easel(s.id), in: c)
    }

    /// N08: Export as Image… / Export as Web Page… from the Library, without opening the Easel: its save panel over the
    /// window, the Library staying where it is.
    @discardableResult
    static func export(_ s: EaselFiles.Summary, _ kind: EaselEditor.ExportKind, in c: WindowController) -> Bool {
        guard s.blockCount > 0 else { return false }
        EaselExporting.run(kind, editor: EaselCenter.shared.editor(for: s.id, store: c.store), window: c.window, controller: c)
        return true
    }

    // MARK: Delete Easel…

    /// The confirmation on screen (the checks answer it with real keys).
    private(set) static weak var deleteAlert: NSAlert?
    /// Easels Delete moved to the Trash this session, and where they are there: ⌘Z that brings a row back puts the
    /// folder back too.
    private(set) static var trashed: [String: URL] = [:]
    private static var putBackToken: (store: SpacesStore, token: Int)?

    /// Library › Easels › Delete Easel…: Arc's question, then the Easel's rows go (one ⌘Z step) and its folder goes to
    /// the Trash.
    static func delete(_ s: EaselFiles.Summary, in c: WindowController, done: @escaping (Bool) -> Void = { _ in }) {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to delete this Easel?"
        // No row shows it any more: no store step to undo, only the Trash's Put Back.
        let undoable = c.store.referencedEaselIDs.contains(s.id)
        alert.informativeText = "“\(s.displayTitle)” moves to the Trash, with everything on it. "
            + (undoable ? "Undo (⌘Z) brings it back." : "You can put it back from the Trash in Finder.")
        alert.addButton(withTitle: "Delete Easel")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        deleteAlert = alert
        alert.beginSheetModal(for: c.window) { [weak c] r in
            guard r == .alertFirstButtonReturn, let c else { return done(false) }
            done(deleteNow(s.id, title: s.displayTitle, in: c))
        }
    }

    @discardableResult
    static func deleteNow(_ id: String, title: String, in c: WindowController) -> Bool {
        let store = c.store, files = EaselCenter.shared.files
        if case .easel(id)? = c.documentPeek?.kind { c.documentPeek?.close(animated: false) }
        EaselCenter.shared.existingEditor(id)?.saveNow(wait: true)
        let tabs: [String]
        do { tabs = try store.deleteEaselRows(id) } catch { NSSound.beep(); return false }
        for w in c.app?.controllers ?? [c] { for t in tabs { w.forgetPage(t) } }
        // Its editor goes without saving (a save would write the folder again).
        EaselFiles.didDelete?([id])
        do {
            if let url = try files.moveToTrash(id) { trashed[id] = url }
        } catch {
            if store.undoLabel == "Delete Easel" { _ = try? store.undo() }
            c.showToast("Airc couldn’t move “\(title)” to the Trash")
            return false
        }
        watchForUndo(store)
        c.reloadAll(animated: false)
        c.showToast("Moved “\(title)” to the Trash")
        return true
    }

    /// While a deleted Easel is in the Trash: a store change that brings one of its rows back (⌘Z) puts it back.
    private static func watchForUndo(_ store: SpacesStore) {
        guard putBackToken == nil else { return }
        let token = store.observe { _ in
            guard !trashed.isEmpty else { return }
            let referenced = store.referencedEaselIDs
            for (id, url) in trashed where referenced.contains(id) {
                trashed[id] = nil
                if !EaselCenter.shared.files.putBack(id, from: url) { NSLog("Airc: couldn't put Easel %@ back from the Trash", id) }
            }
            if trashed.isEmpty, let t = putBackToken {
                putBackToken = nil
                DispatchQueue.main.async { t.store.removeObserver(t.token) }
            }
        }
        putBackToken = (store, token)
    }

    static func thumbnail(_ s: EaselFiles.Summary) -> NSImage? {
        guard let img = EaselPictures.image(s.id, s.thumbnail) else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    }
}

struct LibraryEaselsView: View {
    weak var controller: WindowController?
    let theme: ResolvedTheme
    let revision: Int
    var onOpened: () -> Void
    @State private var query = ""
    @State private var all: [EaselFiles.Summary] = []
    @State private var loaded = false
    @State private var bump = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textTertiary.color)
                TextField("", text: $query, prompt: Text("Search Easels").foregroundStyle(theme.textTertiary.color))
                    .textFieldStyle(.plain).aircFont(AircFont.body).foregroundStyle(theme.text.color)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(theme.fieldFill.color))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            let list = controller.map { LibraryEasels.entries(all, store: $0.store, query: query) } ?? []
            if query.isEmpty, all.contains(where: { $0.blockCount > 0 }) {
                LibraryExportAllCard(theme: theme) { exportAll() }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            if list.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "scribble.variable").font(.system(size: 22, weight: .light)).foregroundStyle(theme.textTertiary.color)
                    Text(!loaded ? "" : query.isEmpty ? "Easels you make (⌃⇧E) show up here, wherever they are in your sidebar." : "No Easels match.")
                        .aircFont(AircFont.callout).foregroundStyle(theme.textSecondary.color).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .padding(.horizontal, 40)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list) { e in
                            LibraryEaselRow(entry: e, theme: theme, where_: placeLabel(e.place)) { peek(e) }
                                .contextMenu {
                                    Button("Open in Peek") { peek(e) }
                                    Button(isArchived(e) ? "Restore" : "Open in Space") { open(e) }
                                    if case .tab = e.place, controller?.store.tabs(showingEasel: e.id).contains(where: { $0.itemID == nil }) == true {
                                        Button("Archive") { archive(e) }
                                    }
                                    if e.summary.blockCount > 0 {
                                        Divider()
                                        Button("Export as Image…") { exportFile(e, .image) }
                                        Button("Export as Web Page…") { exportFile(e, .webPage) }
                                        Button("Share Link…") { export(e, link: true) }
                                    }
                                    Divider()
                                    Button("Delete Easel…") { delete(e) }
                                }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .id(revision &+ bump)
        .onAppear(perform: reload)
        .onChange(of: revision) { _, _ in reload() }
    }

    private func reload() {
        EaselCenter.shared.summaries { list in
            all = list
            loaded = true
        }
    }

    private func isArchived(_ e: LibraryEasels.Entry) -> Bool {
        if case .archived = e.place { return true }
        return false
    }

    private func open(_ e: LibraryEasels.Entry) {
        guard let c = controller, LibraryEasels.open(e.summary, in: c) else { return }
        onOpened()
    }

    /// L05: a click opens the Easel in Peek over the page (Arc's Library); Open in Space is in the Peek and this menu.
    private func peek(_ e: LibraryEasels.Entry) {
        guard let c = controller else { return }
        if LibraryEasels.peek(e.summary, in: c) { onOpened() } else { open(e) }
    }

    private func exportFile(_ e: LibraryEasels.Entry, _ kind: EaselEditor.ExportKind) {
        guard let c = controller else { return }
        LibraryEasels.export(e.summary, kind, in: c)
    }

    private func exportAll() {
        guard let c = controller else { return }
        EaselExportAll.run(in: c)
    }

    private func delete(_ e: LibraryEasels.Entry) {
        guard let c = controller else { return }
        LibraryEasels.delete(e.summary, in: c) { _ in reload() }
    }

    private func export(_ e: LibraryEasels.Entry, link: Bool) {
        guard let c = controller, LibraryEasels.export(e.summary, in: c, link: link) else { return }
        onOpened()
    }

    private func archive(_ e: LibraryEasels.Entry) {
        guard let c = controller, LibraryEasels.archive(e.summary, in: c) else { return }
        bump &+= 1
    }

    private func placeLabel(_ p: LibraryNotes.Place) -> String {
        guard let store = controller?.store else { return "" }
        switch p {
        case .tab(_, let sid), .pinned(_, let sid): return store.space(sid)?.name ?? ""
        case .archived: return "Archived"
        case .none: return "Not in the sidebar"
        }
    }
}

/// Arc's Library card for every Easel ("Your Easels are yours to keep" › Export All Easels): one ZIP of web pages
/// (EaselExportAll). Arc's description opened with Arc winding down; Airc's says only what it does.
private struct LibraryExportAllCard: View {
    let theme: ResolvedTheme
    let onExport: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "archivebox.fill").font(.system(size: 16, weight: .medium)).foregroundStyle(theme.accent.color)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Easels are yours to keep").aircFont(AircFont.row.weight(.semibold)).foregroundStyle(theme.text.color)
                Text("Save all your Easels as web pages you can open anywhere, share, or host yourself.")
                    .aircFont(AircFont.caption).foregroundStyle(theme.textSecondary.color).fixedSize(horizontal: false, vertical: true)
                Button(action: onExport) {
                    HStack(spacing: 4) {
                        Text("Export All Easels")
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    }
                    .aircFont(AircFont.callout.weight(.medium))
                    .foregroundStyle(theme.accentText.color)
                    .opacity(hovered ? 0.8 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .padding(.top, 2)
                .testAnchor("library.easels.exportAll")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(theme.fieldFill.color))
        .testAnchor("library.easels.exportAllCard")
    }
}

private struct LibraryEaselRow: View {
    let entry: LibraryEasels.Entry
    let theme: ResolvedTheme
    let where_: String
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let img = LibraryEasels.thumbnail(entry.summary) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "scribble.variable").font(.system(size: 15)).foregroundStyle(theme.textSecondary.color)
                }
            }
            .frame(width: 44, height: 32)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.fieldFill.color))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.summary.displayTitle).aircFont(AircFont.row).foregroundStyle(theme.text.color).lineLimit(1)
                let n = entry.summary.blockCount
                Text([where_, "\(n) item\(n == 1 ? "" : "s")", entry.summary.updatedAt.formatted(.relative(presentation: .named))]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovered { Text("Open").aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.accentText.color) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(hovered ? theme.hoverFill.color : .clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .help("Open “\(entry.summary.displayTitle)” in Peek")
        .testAnchor("library.easel.\(entry.summary.id)")
    }
}
