// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// SB-36: what a sidebar multi-selection does as one. Every method is one transaction and one undo step, and takes the
// selection's rows in the order the sidebar shows them: a Today tab (`.tab`), a Today split (`.split`), a pinned tab,
// pinned split, folder or Favorite (`.item`). Rows inside a selected folder go with the folder.

extension SpacesStore {
    // MARK: What a selection holds

    /// The live tabs behind a selection, in order: a Today tab, a Today split's panes, a pinned tab's or Favorite's
    /// page, a pinned split's loaded panes, and every loaded tab inside a folder. Each tab once.
    public func liveTabs(of sources: [DragSource]) -> [LiveTab] {
        var seen = Set<String>()
        var out: [LiveTab] = []
        func add(_ t: LiveTab?) { if let t, seen.insert(t.id).inserted { out.append(t) } }
        func addItem(_ id: String) {
            guard let i = item(id) else { return }
            switch i.kind {
            case .tab: add(liveTab(forItem: id))
            case .split: paneTabs(ofSplitItem: id).forEach(add)
            case .folder: children(of: i.container, parent: id).forEach { addItem($0.id) }
            }
        }
        for s in topLevel(sources) {
            switch s {
            case .tab(let id): add(tab(id))
            case .split(let id): splitMembers(id).forEach(add)
            case .item(let id): addItem(id)
            }
        }
        return out
    }

    /// The addresses of a selection ("Copy N Links", ⇧⌘C), in order: a tab's page (`current`, else the stored address),
    /// an unloaded pinned tab's saved address, a split's panes, a folder's links with its nested folders'.
    public func links(of sources: [DragSource], current: (LiveTab) -> String? = { _ in nil }) -> [String] {
        func url(_ t: LiveTab?) -> String? { t.map { current($0) ?? $0.url } }
        func links(ofItem id: String) -> [String] {
            guard let i = item(id) else { return [] }
            switch i.kind {
            case .tab: return [url(liveTab(forItem: id)) ?? i.savedURL].compactMap { $0 }
            case .split, .folder: return children(of: i.container, parent: id).flatMap { links(ofItem: $0.id) }
            }
        }
        return topLevel(sources).flatMap { s -> [String] in
            switch s {
            case .tab(let id): return [url(tab(id))].compactMap { $0 }
            case .split(let id): return splitMembers(id).compactMap(url)
            case .item(let id): return links(ofItem: id)
            }
        }
    }

    /// Whether every selected row is in the pinned section (pinned tabs, pinned splits, folders): "Unpin" rather than "Pin".
    public func allPinned(_ sources: [DragSource]) -> Bool {
        !sources.isEmpty && sources.allSatisfy { s in
            if case .item(let id) = s, case .pinned? = item(id)?.container { return true }
            return false
        }
    }

    /// The tabs "Open in Split View" would show, in pane order: 2–4 tab rows (Today tabs, pinned tabs and Favorites,
    /// loaded or not), no folders and no splits. Nil when the selection can't be one split.
    public func splitCandidates(_ sources: [DragSource]) -> [DragSource]? {
        let rows = topLevel(sources)
        guard (2...Split.maxPanes).contains(rows.count) else { return nil }
        for s in rows {
            switch s {
            case .tab(let id): if tab(id) == nil || split(containing: id) != nil { return nil }
            case .split: return nil
            case .item(let id): if item(id)?.kind != .tab || splitItem(ofPane: id) != nil { return nil }
            }
        }
        return rows
    }

    // MARK: Closing and archiving

    /// ⌘W on a selection ("Close N Tabs"): Today tabs go to the Archive; pinned tabs and Favorites unload and keep their
    /// rows (SB-30), and so do the tabs loaded inside a selected folder. One ⌘Z (or ⇧⌘T) brings every one back. Only
    /// `only` when given (the pages that have closed). Returns the tabs closed: their pages must go.
    @discardableResult
    public func closeTabs(_ sources: [DragSource], only: Set<String>? = nil) throws -> [String] {
        let tabs = liveTabs(of: sources).filter { only?.contains($0.id) ?? true }
        guard !tabs.isEmpty else { return [] }
        try perform("Close Tabs", undoable: true) {
            for t in tabs {
                guard let t = tab(t.id) else { continue }
                if t.isToday { archive(t, reason: .manual) } else { remove(LiveTab.self, t.id) }
            }
        }
        return tabs.map(\.id)
    }

    /// Delete on a selection ("Archive"): Today tabs go to the Archive, and so do pinned tabs, which leave the sidebar;
    /// a folder goes with everything in it, its tabs to the Archive. The Library brings any of them back as a Today
    /// tab; one ⌘Z puts every row back where it was. Favorites stay (they aren't in multi-selections). Returns the live
    /// tabs archived: their pages must go.
    @discardableResult
    public func archive(_ sources: [DragSource]) throws -> [String] {
        let list = topLevel(sources)
        var gone: [String] = []
        try perform("Archive", undoable: true) {
            /// A pinned tab's entry: its page if it has one, else its saved address and name.
            func archiveItem(_ id: String) {
                guard let i = item(id), case .pinned(let sid) = i.container else { return }
                switch i.kind {
                case .tab:
                    if let t = liveTab(forItem: id) {
                        put(ArchiveEntry(tab: t, reason: .manual, at: now()))
                        gone.append(t.id)
                    } else if let saved = i.savedURL {
                        let t = LiveTab(profileID: profile(ofSpace: sid).id, spaceID: sid, url: saved, title: i.displayTitle,
                                        faviconURL: i.faviconURL, createdAt: now())
                        put(ArchiveEntry(tab: t, reason: .manual, at: now()))
                    }
                case .split, .folder:
                    for c in children(of: i.container, parent: id) { archiveItem(c.id) }
                }
            }
            for s in list {
                switch s {
                case .tab(let id):
                    guard let t = tab(id) else { continue }
                    if t.isToday { archive(t, reason: .manual); gone.append(id) } else if let iid = t.itemID { archiveItem(iid); removeItemTree(iid) }
                case .split(let id):
                    for t in splitMembers(id) where t.isToday { archive(t, reason: .manual); gone.append(t.id) }
                case .item(let id):
                    guard case .pinned? = item(id)?.container else { continue }
                    archiveItem(id)
                    removeItemTree(id)
                }
            }
        }
        return gone
    }

    // MARK: Moving

    /// "Pin N Tabs" / "Unpin N Tabs" (⌘D on a selection). With any Today row selected, the Today rows go to the end of
    /// the pinned section, in order; with only pinned rows, they go to the top of Today, in order (folders stay).
    /// Returns the tabs whose page must reload in another profile (a Favorite's into the Space's).
    @discardableResult
    public func togglePin(_ sources: [DragSource], inSpace spaceID: String) throws -> [String] {
        let list = topLevel(sources)
        let unpin = allPinned(list)
        return try perform(unpin ? "Unpin" : "Pin", undoable: true) {
            if unpin {
                return try move(list, to: .today(spaceID: spaceID, index: 0))
            }
            let today = list.filter { s in
                switch s {
                case .tab(let id): return tab(id)?.isToday == true
                case .split: return true
                case .item: return false
                }
            }
            return try move(today, to: .pinned(spaceID: spaceID, parentID: nil, index: pinnedRoots(ofSpace: spaceID).count))
        }
    }

    /// "Move to Space ›": pinned rows (folders too) go to the end of `spaceID`'s pinned section and Today rows to the top
    /// of its Today, each in order; Favorites stay. One undo step. Returns the tabs whose page must reload in the other
    /// Space's profile.
    @discardableResult
    public func move(_ sources: [DragSource], toSpace spaceID: String) throws -> [String] {
        guard space(spaceID) != nil else { throw StoreError.notFound }
        let list = topLevel(sources)
        let pinned = list.filter { s in
            if case .item(let id) = s, case .pinned? = item(id)?.container { return true }
            return false
        }
        let today = list.filter { s in
            switch s {
            case .tab(let id): return tab(id)?.isToday == true
            case .split: return true
            case .item: return false
            }
        }
        return try perform("Move to Space", undoable: true) {
            var reload = try move(pinned, to: .pinned(spaceID: spaceID, parentID: nil, index: pinnedRoots(ofSpace: spaceID).count))
            reload += try move(today, to: .today(spaceID: spaceID, index: 0))
            return reload
        }
    }

    /// "Add to Folder ›": the selection at the end of `folderID`, in order (the folder itself, or one it's inside,
    /// stays out). One undo step. Returns the tabs whose page must reload in another profile.
    @discardableResult
    public func move(_ sources: [DragSource], intoFolder folderID: String) throws -> [String] {
        guard let f = item(folderID), f.kind == .folder, case .pinned(let sid) = f.container else { throw StoreError.notFound }
        let list = topLevel(sources).filter { s in
            guard case .item(let id) = s else { return true }
            return !isAncestorOrSelf(id, of: folderID)
        }
        guard !list.isEmpty else { return [] }
        return try perform("Add to Folder", undoable: true) {
            try move(list, to: .pinned(spaceID: sid, parentID: folderID, index: children(of: f.container, parent: folderID).count))
        }
    }

    /// "New Folder with N Items": a folder holding the selection, in order. When every selected row is pinned under
    /// one parent (⇧-clicked inside a folder), the new folder goes inside that parent, where its first row was (Arc's
    /// nested folders); otherwise at the end of the pinned section. One undo step.
    @discardableResult
    public func newFolder(with sources: [DragSource], named name: String = "New Folder", inSpace spaceID: String) throws -> Item {
        let list = topLevel(sources)
        var parentID: String?
        var index: Int?
        let items = list.compactMap { s -> Item? in if case .item(let id) = s { return item(id) } else { return nil } }
        if items.count == list.count, let first = items.first, first.container == .pinned(spaceID: spaceID),
           items.allSatisfy({ $0.container == first.container && $0.parentID == first.parentID }) {
            parentID = first.parentID
            index = children(of: first.container, parent: first.parentID).firstIndex { $0.id == first.id }
        }
        return try perform("New Folder", undoable: true) {
            let f = try createFolder(named: name, inSpace: spaceID, parentID: parentID, index: index)
            try move(list, to: .pinned(spaceID: spaceID, parentID: f.id, index: 0))
            return item(f.id) ?? f
        }
    }

    // MARK: Copies and splits

    /// "Duplicate" on a selection: a copy of each row just below it (a Today tab's after its original, a pinned tab or
    /// folder below itself; a Today split's panes as Today tabs). Favorites aren't copied. One undo step. Returns the new
    /// tabs' and items' IDs.
    @discardableResult
    public func duplicate(_ sources: [DragSource]) throws -> [String] {
        let list = topLevel(sources)
        var made: [String] = []
        try perform("Duplicate", undoable: true) {
            for s in list {
                switch s {
                case .tab(let id):
                    guard let t = tab(id) else { continue }
                    if let iid = t.itemID { made.append(try duplicateItem(iid).id) } else { made.append(try duplicateTab(id).id) }
                case .split(let id):
                    for t in splitMembers(id) { made.append(try duplicateTab(t.id).id) }
                case .item(let id):
                    guard case .pinned? = item(id)?.container else { continue }
                    made.append(try duplicateItem(id).id)
                }
            }
        }
        return made
    }

    /// "Open in Split View" with 2–4 tab rows selected (`splitCandidates`): their pages side by side, in the order
    /// selected; unloaded pinned tabs and Favorites open first. Shown in `spaceID`'s Today where its first Today row
    /// was. One undo step.
    @discardableResult
    public func openInSplit(_ sources: [DragSource], inSpace spaceID: String, axis: SplitAxis = .horizontal) throws -> Split {
        guard let rows = splitCandidates(sources) else { throw StoreError.invalidMove }
        return try perform("Split View", undoable: true) {
            let ids = try rows.map { s -> String in
                switch s {
                case .tab(let id): return id
                case .item(let id): return try openItem(id, inSpace: spaceID, activate: false).id
                case .split: throw StoreError.invalidMove
                }
            }
            return try createSplit(ids, inSpace: spaceID, axis: axis, focused: ids.first)
        }
    }

    /// A Today split's tabs, in pane order.
    private func splitMembers(_ id: String) -> [LiveTab] { split(id).map { members(of: $0) } ?? [] }

    private func isAncestorOrSelf(_ ancestor: String, of id: String) -> Bool {
        var cur: String? = id
        var n = 0
        while let c = cur, n < 256 {
            if c == ancestor { return true }
            cur = item(c)?.parentID
            n += 1
        }
        return false
    }
}
