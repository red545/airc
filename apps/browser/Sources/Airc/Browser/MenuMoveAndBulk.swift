// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// S09/S11 (docs/qa/parity-audit.md), the last of Arc 1.171's sidebar menu items that fit Airc's model:
///   - a tab's, pinned row's or folder's Move to ›: after the other Spaces, this Space's folders (Arc's
///     SidebarMenu+MoveMenu: Spaces, then folders). The row goes to the end of the folder, as one ⌘Z;
///   - a multi-selection's Archive Tabs Below and Archive Other Tabs (Arc's mixed-selection menu: "Deletes all tabs from
///     the sidebar that are below the selected ones", "Deletes all unselected unpinned tabs from the sidebar"), one ⌘Z;
///   - Command Bar: Arc's Mute All Tabs / Unmute All Tabs, Rename Current Tab and Pin to “Folder”.
extension WindowController {
    // MARK: Move to › folders

    /// The folders of `spaceID` a row can move into: the pinned section's (nested ones indented), then Today's (only
    /// with `today`: a Today tab can go into either, a pinned row or folder stays in its own section).
    /// `excluding` leaves out a folder and everything inside it (a folder can't go into itself); `parent` is the folder
    /// the row is in now.
    func moveFolderTargets(inSpace spaceID: String, pinned: Bool = true, today: Bool = true, excluding: String? = nil,
                           parent: String? = nil) -> [(folder: Item, depth: Int)] {
        var out: [(Item, Int)] = []
        func walk(_ container: ItemContainer, _ under: String?, _ depth: Int) {
            for f in store.children(of: container, parent: under) where f.kind == .folder && f.id != excluding {
                if f.id != parent { out.append((f, depth)) }
                walk(container, f.id, depth + 1)
            }
        }
        if pinned { walk(.pinned(spaceID: spaceID), nil, 0) }
        if today { walk(.today(spaceID: spaceID), nil, 0) }
        return out
    }

    /// Adds this Space's folders to a Move to › submenu, after a line. Nothing when there are none.
    func addMoveFolderRows(to sub: NSMenu, source: DragSource, spaceID: String, excluding: String? = nil, parent: String? = nil) {
        var pinned = true, today = true
        if case .item(let id) = source, let it = store.item(id) { pinned = !it.isTodayFolder; today = it.isTodayFolder }
        let folders = moveFolderTargets(inSpace: spaceID, pinned: pinned, today: today, excluding: excluding, parent: parent)
        guard !folders.isEmpty else { return }
        if !sub.items.isEmpty, sub.items.last?.isSeparatorItem == false { sub.addItem(.separator()) }
        for (f, depth) in folders {
            let icon = f.icon ?? ""
            let row = sub.add(icon.isEmpty ? f.displayTitle : "\(icon)  \(f.displayTitle)") { [weak self] in self?.moveIntoFolder(source, folderID: f.id) }
            row.indentationLevel = depth
            if icon.isEmpty { row.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil) }
        }
    }

    /// The row goes to the end of the folder (opened first, so it stays in sight). One ⌘Z ("Add to Folder").
    func moveIntoFolder(_ source: DragSource, folderID: String) {
        do {
            if store.item(folderID)?.isCollapsed == true { try store.toggleFolder(folderID) }
            reloadPagesInNewProfile(try store.move([source], intoFolder: folderID))
        } catch { NSSound.beep() }
    }

    // MARK: Archive Tabs Below / Archive Other Tabs on a selection

    /// The Today tabs below the lowest selected one, not selected and not on screen in a window.
    func selectionTabsBelow(_ ids: [String], spaceID: String) -> [String] {
        let today = store.todayRowTabs(ofSpace: spaceID).map(\.id)
        let picked = selectedTodayTabs(ids, spaceID: spaceID)
        guard let last = today.lastIndex(where: picked.contains) else { return [] }
        let kept = visibleTabIDs
        return today[(last + 1)...].filter { !picked.contains($0) && !kept.contains($0) }
    }

    /// Every Today tab of the Space that isn't selected and isn't on screen in a window.
    func selectionOtherTabs(_ ids: [String], spaceID: String) -> [String] {
        let picked = selectedTodayTabs(ids, spaceID: spaceID)
        guard !picked.isEmpty else { return [] }
        let kept = visibleTabIDs
        return store.todayRowTabs(ofSpace: spaceID).map(\.id).filter { !picked.contains($0) && !kept.contains($0) }
    }

    /// The selected rows' Today tabs (a selected Today folder's tabs and a split's panes count as selected).
    private func selectedTodayTabs(_ ids: [String], spaceID: String) -> Set<String> {
        let today = Set(store.todayRowTabs(ofSpace: spaceID).map(\.id))
        return Set(store.liveTabs(of: selectionSources(ids)).map(\.id)).intersection(today)
    }

    func addSelectionArchiveRows(to m: NSMenu, ids: [String], spaceID: String) {
        let below = selectionTabsBelow(ids, spaceID: spaceID)
        let others = selectionOtherTabs(ids, spaceID: spaceID)
        guard !selectedTodayTabs(ids, spaceID: spaceID).isEmpty else { return }
        m.add("Archive Tabs Below") { [weak self] in self?.archiveSelection(ids, tabs: { $0.selectionTabsBelow(ids, spaceID: spaceID) }, label: "Archive Tabs Below") }
            .isEnabled = !below.isEmpty
        m.add("Archive Other Tabs") { [weak self] in self?.archiveSelection(ids, tabs: { $0.selectionOtherTabs(ids, spaceID: spaceID) }, label: "Archive Other Tabs") }
            .isEnabled = !others.isEmpty
    }

    /// The tabs go to the Archive as Archive Tabs Below does for one tab: pages that ask "Leave site?" ask first; ⌘Z
    /// brings them back. The selection stays.
    private func archiveSelection(_ ids: [String], tabs: (WindowController) -> [String], label: String) {
        guard archiveQueue == nil else { return NSSound.beep() }
        let list = tabs(self)
        guard !list.isEmpty else { return NSSound.beep() }
        closeThenArchive(list, reason: .manual, label: label)
    }

    // MARK: Command Bar

    /// Arc's Command Bar actions with no menu row: Mute All Tabs / Unmute All Tabs, Rename Current Tab, Pin to “Folder”.
    func menuParityCommandActions() -> [CommandAction] {
        var a: [CommandAction] = []
        let loaded = pages.filter { !$0.value.isClosed && store.tab($0.key) != nil }
        if loaded.contains(where: { $0.value.isAudible && !$0.value.isMuted }) {
            a.append(.init(title: "Mute All Tabs", symbol: "speaker.slash", hint: "", keywords: ["mute", "sound", "audio", "silence", "quiet", "all"]) { [weak self] in
                self?.setAllTabsMuted(true)
            })
        }
        if loaded.contains(where: { $0.value.isMuted }) {
            a.append(.init(title: "Unmute All Tabs", symbol: "speaker.wave.2", hint: "", keywords: ["unmute", "sound", "audio", "all"]) { [weak self] in
                self?.setAllTabsMuted(false)
            })
        }
        guard let t = currentTab, !store.isNoteTab(t.id) else { return a }
        let item = store.item(t.itemID)
        if item?.isFavorite != true {
            a.append(.init(title: "Rename Current Tab", symbol: "pencil", hint: "", keywords: ["rename", "name", "title", "tab"]) { [weak self] in
                self?.renameCurrentTab()
            })
            let source: DragSource = t.isToday ? .tab(t.id) : .item(t.itemID ?? "")
            for (f, _) in moveFolderTargets(inSpace: currentSpaceID, today: false, parent: item?.parentID) {
                // Arc: "Pin to <folder>" ("Action to pin this tab to a folder").
                a.append(.init(title: "Pin to “\(TextLimits.clip(f.displayTitle))”", symbol: "folder", hint: "",
                               keywords: ["pin", "folder", "move", "add"]) { [weak self] in self?.moveIntoFolder(source, folderID: f.id) })
            }
        }
        return a
    }

    /// Mute All Tabs / Unmute All Tabs: every loaded tab in this window, as each row's Mute does.
    func setAllTabsMuted(_ muted: Bool) {
        let ids = pages.filter { !$0.value.isClosed && store.tab($0.key) != nil && $0.value.isMuted != muted }.map(\.key)
        guard !ids.isEmpty else { return NSSound.beep() }
        for id in ids {
            try? store.setMuted(id, muted)
            engineTab(for: id)?.isMuted = muted
            refreshRow(id)
        }
    }

    /// Rename Current Tab: the shown tab's row takes a new name, as its menu's Rename… does (a Today tab is pinned first).
    func renameCurrentTab() {
        guard let t = currentTab else { return NSSound.beep() }
        if t.isToday { return renameTodayTab(t.id) }
        guard let id = t.itemID, store.item(id)?.isFavorite == false else { return NSSound.beep() }
        renameItemFromMenu(id)
    }
}
