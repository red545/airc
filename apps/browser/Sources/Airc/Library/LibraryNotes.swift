// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// P10a (L05): Library › Notes, every note in one list (Arc's "Easels & Notes" page), so a note can be found and opened
/// wherever its row is: in another Space, a closed folder or a folded pinned section, archived, or nowhere any more.
/// Newest edit first; the search matches titles and text. The notes are AircKit's (Notes.swift), read only here.
enum LibraryNotes {
    /// Where a note's row is.
    enum Place: Equatable {
        /// An open tab (pinned or Today) in a Space.
        case tab(id: String, spaceID: String)
        /// A pinned row whose page isn't loaded.
        case pinned(itemID: String, spaceID: String)
        /// Closed: in the Archive.
        case archived(entryID: String)
        /// No row points at it (it comes back as a Today tab when opened).
        case none
    }

    struct Entry: Identifiable, Equatable {
        let note: Note
        let place: Place
        var id: String { note.id }
    }

    static func place(of note: Note, in store: SpacesStore) -> Place {
        let url = note.url
        if let t = store.state.tabs.values.filter({ $0.url == url }).max(by: { $0.lastActiveAt < $1.lastActiveAt }), let sid = t.spaceID {
            return .tab(id: t.id, spaceID: sid)
        }
        if let i = store.state.items.values.first(where: { $0.savedURL == url }), case .pinned(let sid) = i.container {
            return .pinned(itemID: i.id, spaceID: sid)
        }
        if let e = store.state.archive.values.filter({ $0.tab.url == url }).max(by: { $0.archivedAt < $1.archivedAt }) {
            return .archived(entryID: e.id)
        }
        return .none
    }

    /// Every note, newest edit first, matching `query` in its title or text.
    static func entries(_ store: SpacesStore, query: String = "") -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.state.notes.values
            .filter { n in q.isEmpty || CommandSearch.score(q, in: n.displayTitle) != nil || n.document.plainText.localizedCaseInsensitiveContains(q) }
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
            .map { Entry(note: $0, place: place(of: $0, in: store)) }
    }

    /// Opens the note where its row is (switching Space, opening the folders above it), restores it from the Archive,
    /// or gives it a Today tab in the current Space when no row points at it. False when it couldn't.
    @discardableResult
    static func open(_ note: Note, in c: WindowController) -> Bool {
        let store = c.store
        var tabID: String?
        switch place(of: note, in: store) {
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
            tabID = (try? store.openTab(url: note.url, inSpace: c.currentSpaceID, title: note.displayTitle))?.id
        }
        guard let id = tabID else { return false }
        c.show(id)
        c.revealTabInSidebar()
        return true
    }

    /// The first line of text after the title, for the row's second line.
    static func excerpt(_ note: Note) -> String {
        let lines = note.document.plainText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.dropFirst().first ?? ""
    }
}

struct LibraryNotesView: View {
    weak var controller: WindowController?
    let theme: ResolvedTheme
    let revision: Int
    var onOpened: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textTertiary.color)
                TextField("", text: $query, prompt: Text("Search notes").foregroundStyle(theme.textTertiary.color))
                    .textFieldStyle(.plain).aircFont(AircFont.body).foregroundStyle(theme.text.color)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: AircRadius.row, style: .continuous).fill(theme.fieldFill.color))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            let list = controller.map { LibraryNotes.entries($0.store, query: query) } ?? []
            if list.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "note.text").font(.system(size: 22, weight: .light)).foregroundStyle(theme.textTertiary.color)
                    Text(query.isEmpty ? "Notes you write (⌃⇧N) show up here, wherever they are in your sidebar." : "No notes match.")
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
                            LibraryNoteRow(entry: e, theme: theme, where_: placeLabel(e.place)) { open(e) }
                                .contextMenu {
                                    Button("Open") { open(e) }
                                    Button("Copy as Markdown") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(e.note.document.markdown, forType: .string)
                                    }
                                }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .id(revision)
    }

    private func open(_ e: LibraryNotes.Entry) {
        guard let c = controller, LibraryNotes.open(e.note, in: c) else { return }
        onOpened()
    }

    /// Where the note is: its Space, "Archived", or nowhere.
    private func placeLabel(_ p: LibraryNotes.Place) -> String {
        guard let store = controller?.store else { return "" }
        switch p {
        case .tab(_, let sid), .pinned(_, let sid): return store.space(sid)?.name ?? ""
        case .archived: return "Archived"
        case .none: return "Not in the sidebar"
        }
    }
}

private struct LibraryNoteRow: View {
    let entry: LibraryNotes.Entry
    let theme: ResolvedTheme
    let where_: String
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "note.text").font(.system(size: 14, weight: .regular)).foregroundStyle(theme.textSecondary.color)
                .frame(width: AircMetrics.Row.favicon, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.note.displayTitle).aircFont(AircFont.row).foregroundStyle(theme.text.color).lineLimit(1)
                let excerpt = LibraryNotes.excerpt(entry.note)
                if !excerpt.isEmpty {
                    Text(excerpt).aircFont(AircFont.callout).foregroundStyle(theme.textSecondary.color).lineLimit(1)
                }
                Text([where_, entry.note.updatedAt.formatted(.relative(presentation: .named))].filter { !$0.isEmpty }.joined(separator: " · "))
                    .aircFont(AircFont.caption).foregroundStyle(theme.textTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hovered { Text("Open").aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.accent.color) }
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
        .help("Open “\(entry.note.displayTitle)”")
        .testAnchor("library.note.\(entry.note.id)")
    }
}
