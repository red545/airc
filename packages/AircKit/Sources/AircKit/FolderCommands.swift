// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// A folder's links, as its menu copies them (Arc's "Copy All Links" and "Copy All Links as Markdown"): in the order
/// the sidebar shows them, nested folders in place, a pinned split's panes in pane order. Notes have no link.
public struct FolderLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case link(url: String), folder }
    public var title: String
    public var kind: Kind
    /// 0 for the folder's own rows, 1 inside a nested folder, and so on.
    public var depth: Int

    public init(title: String, kind: Kind, depth: Int) {
        self.title = title
        self.kind = kind
        self.depth = depth
    }

    public var url: String? { if case .link(let u) = kind { return u }; return nil }
}

/// The folder and Space commands of Arc's menus: the links of a folder (plain or Markdown), Expand and Collapse All
/// Folders, and the pinned tabs "Reset all tabs in this Space" takes back to their saved URLs.
extension SpacesStore {
    /// Every row inside folder `id`. A tab's link is its saved URL (the one its row stands for), its title the row's.
    public func folderLinks(_ id: String) -> [FolderLink] {
        guard let f = item(id), f.kind == .folder else { return [] }
        var out: [FolderLink] = []
        func walk(_ parent: String, depth: Int) {
            for c in children(of: f.container, parent: parent) {
                switch c.kind {
                case .folder:
                    out.append(FolderLink(title: c.displayTitle, kind: .folder, depth: depth))
                    walk(c.id, depth: depth + 1)
                case .split:
                    for p in children(of: c.container, parent: c.id) { add(p, depth: depth) }
                case .tab:
                    add(c, depth: depth)
                }
            }
        }
        func add(_ i: Item, depth: Int) {
            guard let u = i.savedURL, !NoteURL.isNote(u) else { return }
            out.append(FolderLink(title: i.displayTitle, kind: .link(url: u), depth: depth))
        }
        walk(id, depth: 0)
        return out
    }

    /// "Copy All Links": one address per line, in order.
    public func folderLinksText(_ id: String, clean: (String) -> String = { $0 }) -> String {
        folderLinks(id).compactMap(\.url).map(clean).joined(separator: "\n")
    }

    /// "Copy All Links as Markdown": a list of `[title](url)` links, each nested folder an item with its own rows
    /// indented under it, so the titles, order and nesting paste as they are in the sidebar.
    public func folderLinksMarkdown(_ id: String, clean: (String) -> String = { $0 }) -> String {
        folderLinks(id).map { l in
            let indent = String(repeating: "  ", count: l.depth)
            switch l.kind {
            case .link(let u): return indent + "- " + URLRules.markdownLink(title: l.title, url: clean(u))
            case .folder: return indent + "- " + URLRules.markdownListText(l.title)
            }
        }.joined(separator: "\n")
    }

    /// A multi-selection's links as Markdown ("Copy N Links as Markdown"), in the selection's order: a tab's page
    /// (`current` gives its address and title, else the stored ones), an unloaded pinned tab's saved address and name,
    /// a split's panes, a folder as an item with its rows under it. A folder's rows that are also selected count once.
    public func linksMarkdown(of sources: [DragSource], current: (LiveTab) -> (url: String, title: String)? = { _ in nil },
                              clean: (String) -> String = { $0 }) -> String {
        var lines: [String] = []
        func link(_ title: String, _ url: String) {
            guard !NoteURL.isNote(url) else { return }
            lines.append("- " + URLRules.markdownLink(title: title, url: clean(url)))
        }
        func add(tab t: LiveTab) {
            let c = current(t)
            let title = c?.title.isEmpty == false ? c!.title : (item(t.itemID)?.displayTitle ?? t.displayTitle)
            link(title, c?.url ?? t.url)
        }
        func add(item id: String) {
            guard let i = item(id) else { return }
            switch i.kind {
            case .folder:
                lines.append("- " + URLRules.markdownListText(i.displayTitle))
                let md = folderLinksMarkdown(id, clean: clean)
                if !md.isEmpty { lines += md.split(separator: "\n").map { "  " + $0 } }
            case .split: children(of: i.container, parent: id).forEach { add(item: $0.id) }
            case .tab:
                if let t = liveTab(forItem: id) { add(tab: t) } else if let u = i.savedURL { link(i.displayTitle, u) }
            }
        }
        for s in topLevel(sources) {
            switch s {
            case .tab(let id): if let t = tab(id) { add(tab: t) }
            case .split(let id): (split(id)?.tabIDs ?? []).compactMap { tab($0) }.forEach(add(tab:))
            case .item(let id): add(item: id)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The folders of a Space's pinned section, nested ones too.
    public func folders(inSpace sid: String) -> [Item] {
        state.items.values.filter { $0.kind == .folder && $0.spaceID == sid }
    }

    /// Arc's "Expand All Folders" / "Collapse All Folders" (nested ones too). Returns how many changed.
    @discardableResult
    public func setAllFolders(collapsed: Bool, inSpace sid: String) throws -> Int {
        let changing = folders(inSpace: sid).filter { $0.isCollapsed != collapsed }
        guard !changing.isEmpty else { return 0 }
        try perform(nil) {
            for var f in changing {
                f.isCollapsed = collapsed
                put(f)
            }
        }
        return changing.count
    }

    /// Undo labels of a reset: one tab, several.
    public static let resetTabLabel = "Reset Tab"
    public static let resetTabsLabel = "Reset Tabs"

    /// Back to Pinned URL and Reset all tabs in this Space, as one ⌘Z step: each tab away from its saved URL gets it.
    /// Returns the addresses they had (⌘Z puts those back; the window sends each page after its own).
    @discardableResult
    public func resetToSavedURLs(_ tabIDs: [String]) throws -> [String: String] {
        let targets = tabIDs.filter(isDrifted).compactMap { id in tab(id).flatMap { t in item(t.itemID)?.savedURL.map { (t, $0) } } }
        guard !targets.isEmpty else { return [:] }
        var before: [String: String] = [:]
        try perform(targets.count == 1 ? Self.resetTabLabel : Self.resetTabsLabel, undoable: true) {
            for (t0, saved) in targets {
                var t = t0
                before[t.id] = t.url
                t.url = saved
                put(t)
            }
        }
        return before
    }

    /// "Reset all tabs in this Space": its pinned tabs (in folders and pinned splits too) whose page is away from the
    /// saved URL, in sidebar order. Favorites belong to the profile, not the Space, and Today tabs have no saved URL.
    public func driftedPinnedTabs(inSpace sid: String) -> [LiveTab] {
        var out: [LiveTab] = []
        func walk(_ parent: String?) {
            for c in children(of: .pinned(spaceID: sid), parent: parent) {
                switch c.kind {
                case .folder, .split: walk(c.id)
                case .tab: if let t = liveTab(forItem: c.id), isDrifted(t.id) { out.append(t) }
                }
            }
        }
        walk(nil)
        return out
    }

    /// P01c, Arc's reset while a folder is focused ("Reset all tabs in this Folder"): the pinned tabs inside folder
    /// `folderID` (nested folders and pinned splits too) whose page is away from the saved URL, in sidebar order.
    public func driftedPinnedTabs(inFolder folderID: String) -> [LiveTab] {
        guard let f = item(folderID), f.kind == .folder else { return [] }
        var out: [LiveTab] = []
        func walk(_ parent: String) {
            for c in children(of: f.container, parent: parent) {
                switch c.kind {
                case .folder, .split: walk(c.id)
                case .tab: if let t = liveTab(forItem: c.id), isDrifted(t.id) { out.append(t) }
                }
            }
        }
        walk(folderID)
        return out
    }

    /// P01c, Arc's folder menu "Turn into Space" (its newSpaceFromFolder): a new Space right after the folder's, in the
    /// same profile and theme, named after the folder and with its emoji. The folder's rows become the new Space's
    /// pinned section, in order, nested folders as they are; the folder goes. One undo step. Returns the new Space and
    /// the tabs whose page must reload in another profile (none: the profile stays).
    @discardableResult
    public func turnFolderIntoSpace(_ folderID: String) throws -> (space: Space, reload: [String]) {
        guard let f = item(folderID), f.kind == .folder, case .pinned(let sid) = f.container, let from = space(sid) else {
            throw StoreError.notFound
        }
        return try perform("Turn into Space", undoable: true) {
            let name = (f.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let s = try createSpace(name: name.isEmpty ? "Folder" : name, icon: f.icon.map { SpaceIcon.emoji($0) }, theme: from.theme,
                                    profileID: from.profileID, after: sid)
            let rows = children(of: f.container, parent: folderID).map { DragSource.item($0.id) }
            let reload = try move(rows, to: .pinned(spaceID: s.id, parentID: nil, index: 0))
            try deleteItem(folderID)
            return (space(s.id) ?? s, reload)
        }
    }
}

extension URLRules {
    /// A folder name as a Markdown list item's text: brackets, backticks and backslashes escaped, one line.
    public static func markdownListText(_ text: String) -> String {
        let one = text.components(separatedBy: .newlines).joined(separator: " ")
        return one.reduce(into: "") { r, c in
            if "\\[]`*_".contains(c) { r.append("\\") }
            r.append(c)
        }
    }
}
