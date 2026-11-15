// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// An Easel in the sidebar is an ordinary tab or pinned item whose address is the Easel's (`airc-easel:<id>`), so it
// drags, pins, goes into folders, archives and restores by the tab rules. What's on it lives in its own folder on disk
// (EaselFiles.swift), not in the store: the store's schema doesn't change, and Easels stay on this Mac (their rows are
// local-only in Sync, LocalDocumentURL).

/// An Easel's address: what its tab or pinned item has for a URL. Never loaded by an engine.
public enum EaselURL {
    public static let scheme = "airc-easel"

    public static func make(_ id: String) -> String { "\(scheme):\(id)" }

    /// The Easel an address is for, or nil when it isn't an Easel's.
    public static func easelID(_ url: String?) -> String? {
        guard let url, url.hasPrefix(scheme + ":") else { return nil }
        let id = String(url.dropFirst(scheme.count + 1))
        return EaselFiles.isValidID(id) ? id : nil
    }

    public static func isEasel(_ url: String?) -> Bool { easelID(url) != nil }

    /// What an Easel with no title is called (Arc's "Untitled Easel"; its menu item "New Easel").
    public static let untitled = "Untitled Easel"
}

/// Addresses that are Airc's own documents (a note, an Easel): never loaded by an engine, never synced.
public enum LocalDocumentURL {
    /// Notes, Easels and the What's new tab (whatsnew2): no engine page, not synced, not moved like a link.
    public static func isLocal(_ url: String?) -> Bool { NoteURL.isNote(url) || EaselURL.isEasel(url) || WhatsNewURL.isPage(url) }
}

extension EaselFiles {
    /// The Easels row copies made this session (P19c): an undone copy deletes its Easel again.
    nonisolated(unsafe) static var madeCopies = Set<String>()
    /// The app's: Easels that were just deleted (an undone copy's), so their editors go without saving.
    nonisolated(unsafe) public static var didDelete: (([String]) -> Void)?

    /// Deletes Easel `id`'s folder: its document, history and pictures.
    public func delete(_ id: String) {
        guard Self.isValidID(id) else { return }
        try? FileManager.default.removeItem(at: folder(id))
    }
}

// MARK: - Store actions

extension SpacesStore {
    public func isEaselTab(_ tabID: String?) -> Bool { EaselURL.isEasel(tab(tabID)?.url) }

    /// The Easel a tab shows, if it's an Easel's tab.
    public func easelID(forTab tabID: String?) -> String? { EaselURL.easelID(tab(tabID)?.url) }

    /// Arc's New Easel (⌃E, File › New Easel, the Command Bar, the sidebar's "+"): a row for Easel `id` (whose document
    /// the app writes), pinned at the bottom of `spaceID`'s pinned tabs (or in folder `parentID`), its tab opened and
    /// made the Space's last used. `pinned: false` opens it at the top of Today. One store transaction; `undoLabel`
    /// makes it a ⌘Z step (P19d: Add to Airc, as Add Shared Space is). New Easel itself isn't undoable.
    @discardableResult
    public func createEasel(_ id: String = newID(), inSpace spaceID: String, pinned: Bool = true, parentID: String? = nil,
                            title: String = "", undoLabel: String? = nil) throws -> LiveTab {
        guard let s = space(spaceID), EaselFiles.isValidID(id) else { throw StoreError.notFound }
        if let parentID {
            guard let f = item(parentID), f.kind == .folder, f.container == .pinned(spaceID: spaceID) else { throw StoreError.invalidMove }
        }
        let url = EaselURL.make(id)
        let name = Self.easelRowTitle(title)
        var tab = LiveTab(profileID: s.profileID, spaceID: spaceID, url: url, title: name, createdAt: now())
        try perform(undoLabel ?? "New Easel", undoable: undoLabel != nil) {
            if pinned {
                let siblings = children(of: .pinned(spaceID: spaceID), parent: parentID)
                let item = Item(kind: .tab, container: .pinned(spaceID: spaceID), parentID: parentID,
                                order: Ordering.insertion(at: siblings.count, in: siblings.map(\.order)),
                                savedURL: url, pageTitle: name, createdAt: now())
                put(item)
                tab.itemID = item.id
            } else {
                tab.order = topOfToday(spaceID)
            }
            put(tab)
            markActive(tab.id, inSpace: spaceID)
        }
        return self.tab(tab.id)!
    }

    /// A Today tab for an Easel no row shows any more (Library › Easels › Open).
    @discardableResult
    public func reopenEasel(_ id: String, title: String, inSpace spaceID: String) throws -> LiveTab {
        try createEasel(id, inSpace: spaceID, pinned: false, title: title)
    }

    static func easelRowTitle(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? EaselURL.untitled : String(t.prefix(EaselDocument.maxTitleLength))
    }

    /// The Easel's title field: every row of Easel `id` shows `title` (a pinned row's own name gives way to it). As
    /// typed: in memory at once, on disk with the next flush, never a store undo step.
    public func renameEaselRows(_ id: String, to title: String) {
        let url = EaselURL.make(id), name = Self.easelRowTitle(title)
        let tabs = state.tabs.values.filter { $0.url == url && $0.title != name }
        let items = state.items.values.filter { $0.savedURL == url && ($0.pageTitle != name || $0.title != nil) }
        guard !tabs.isEmpty || !items.isEmpty else { return }
        try? perform(nil, deferred: true, contentOnly: true) {
            for var t in tabs { t.title = name; put(t) }
            for var i in items { i.pageTitle = name; i.title = nil; put(i) }
        }
    }

    /// A name a pinned row of Easel `id` was given in the sidebar (Rename), for the editor's title field.
    public func easelRowName(_ id: String) -> String? {
        let url = EaselURL.make(id)
        return state.items.values.filter { $0.savedURL == url }.compactMap(\.title).sorted().first
    }

    /// The live tabs showing Easel `id`.
    public func tabs(showingEasel id: String) -> [LiveTab] {
        let url = EaselURL.make(id)
        return state.tabs.values.filter { $0.url == url }.sorted { $0.id < $1.id }
    }

    /// The archive entries of Easel `id`, newest first.
    public func archiveEntries(ofEasel id: String) -> [ArchiveEntry] {
        let url = EaselURL.make(id)
        return state.archive.values.filter { $0.tab.url == url }.sorted { $0.archivedAt > $1.archivedAt }
    }

    /// Inside a transaction (`copiedAddress`): a copied Easel row (⌥-drag, Duplicate) gets an Easel of its own with
    /// the same blocks and pictures, as a note's row gets a note of its own (P19b). Without the app's Easels folder, or
    /// when the copy can't be written, the copy keeps the address.
    func copiedEaselAddress(_ url: String) -> String {
        guard let id = EaselURL.easelID(url), let files = EaselFiles.shared, let copy = files.duplicate(id, now: now()) else { return url }
        EaselFiles.madeCopies.insert(copy)
        return EaselURL.make(copy)
    }

    /// Before ⌘Z (P19c): the Easels that row copies made (`copiedEaselAddress`) and that rows the step being undone
    /// touched point at.
    func easelCopies(touchedBy refs: some Collection<EntityRef>) -> Set<String> {
        guard !EaselFiles.madeCopies.isEmpty else { return [] }
        var ids = Set<String>()
        for r in refs {
            let url: String? = switch r.kind {
            case .tab: tab(r.id)?.url
            case .item: item(r.id)?.savedURL
            default: nil
            }
            if let id = EaselURL.easelID(url), EaselFiles.madeCopies.contains(id) { ids.insert(id) }
        }
        return ids
    }

    /// After ⌘Z (P19c): of those copies, the ones no row points at any more are deleted, so undoing a duplicate leaves
    /// no Easel behind in Library › Easels. The app lets go of their editors without saving (`EaselFiles.didDelete`).
    func deleteUndoneEaselCopies(_ ids: Set<String>) {
        guard !ids.isEmpty, let files = EaselFiles.shared else { return }
        let gone = ids.subtracting(referencedEaselIDs).sorted()
        guard !gone.isEmpty else { return }
        for id in gone {
            files.delete(id)
            EaselFiles.madeCopies.remove(id)
        }
        EaselFiles.didDelete?(gone)
    }

    /// Whether tab `tabID` can be a split's pane: an Easel never is (its canvas isn't a page; P19b guards every way into
    /// a split: ⌥-click, menus, drags, New Split View).
    public func canBeSplitPane(_ tabID: String?) -> Bool {
        guard let t = tab(tabID) else { return false }
        return !EaselURL.isEasel(t.url) && !EaselURL.isEasel(item(t.itemID)?.savedURL)
    }

    /// The Easels some tab, pinned item or archive entry points at.
    public var referencedEaselIDs: Set<String> {
        var ids = Set<String>()
        for t in state.tabs.values { if let id = EaselURL.easelID(t.url) { ids.insert(id) } }
        for i in state.items.values { if let id = EaselURL.easelID(i.savedURL) { ids.insert(id) } }
        for a in state.archive.values { if let id = EaselURL.easelID(a.tab.url) { ids.insert(id) } }
        return ids
    }
}
