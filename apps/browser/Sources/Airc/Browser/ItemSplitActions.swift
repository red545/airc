// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

// SV-2 pinned and Favorite splits in the window (AircKit's ItemSplits.swift has the rules). A pinned split's row and a
// Favorite split's tile open every pane; closing one frees all its pages and keeps the item (SB-30); each pane resets
// to its own saved URL (SB-31). SB-15: a page that isn't on screen is freed after Settings → General's timeout (MEM-3),
// Favorites and pinned panes included; their rows and tiles then draw it at half strength and a click loads it again.

/// SV-2: a pinned or Favorite split closing pane by pane: `current` is deciding ("Leave site?"), `rest` follow, and
/// `focused` is the pane the close was asked for (⌘W, the row's ✕, Close).
struct PaneCloseQueue {
    var focused: String
    var current: String?
    var rest: [String] = []
    var started = Date()
}

extension WindowController {
    /// No page, or one the engine has freed (Chromium's discard keeps the page object; WebKit's unload drops it).
    func isPageUnloaded(_ tabID: String?) -> Bool {
        guard let tabID, let page = engineTab(for: tabID) else { return true }
        #if canImport(AircCore)
        if let chromium = app?.engine as? ChromiumEngine { return chromium.isDiscarded(page) }
        #endif
        _ = page
        return false
    }

    /// Telemetry (favorite.add): whether a drop at `destination` makes `source` a Favorite tile it wasn't.
    func makesNewFavorite(_ source: DragSource, _ destination: DropDestination) -> Bool {
        guard case .favorites = destination else { return false }
        let item: Item? = switch source {
        case .item(let id): store.item(id)
        case .tab(let id): store.item(store.tab(id)?.itemID)
        case .split: nil
        }
        return !(item?.isFavorite == true && item?.parentID == nil)
    }

    /// A press on one pane of a pinned split's row: every pane opens, that one focused.
    func openPane(_ paneID: String) {
        guard let t = try? store.openItem(paneID, inSpace: currentSpaceID) else { return }
        show(t.id)
    }

    /// Closes a pinned or Favorite split: every pane's page goes, the row or tile stays (SB-30).
    func closeItemSplit(_ itemID: String) {
        guard let t = store.liveTab(forSplitItem: itemID) else { return }
        closeTab(t.id)
    }

    /// SV-2: closing (or unloading) a pinned or Favorite split closes each pane's page in turn, so every pane that would
    /// lose changes asks "Leave site?", not only the focused one. Panes that would ask go first, one question at a time
    /// in pane order; Stay on any stops there and keeps the split open (panes that had already closed load again). Once
    /// every page has closed, the split closes as before and its row or tile stays (SB-30). False when `tabID` isn't a
    /// pane of one with pages open, which is the plain close.
    func closePanesInTurn(_ tabID: String) -> Bool {
        guard !panesClosingWith(tabID).isEmpty, let s = store.splitItem(ofPane: store.tab(tabID)?.itemID) else { return false }
        // Already closing: one question at a time (unless the engine never reported back on the last one).
        if let q = paneCloseQueue {
            if Date().timeIntervalSince(q.started) < 10 { return true }
            paneCloseQueue = nil
        }
        let live = store.paneTabs(ofSplitItem: s.id).map(\.id).filter { engineTab(for: $0).map { !$0.isClosed } ?? false }
        guard !live.isEmpty else { return false }
        paneCloseQueue = PaneCloseQueue(focused: tabID)
        // Which pages would ask (each answers itself, 0.5 s at most): those go first, so a Stay closes nothing else.
        var asks: Set<String> = [], left = live.count, started = false
        let start = { [weak self] in
            guard let self, !started else { return }
            started = true
            guard self.paneCloseQueue?.focused == tabID, self.paneCloseQueue?.current == nil else { return }
            self.paneCloseQueue?.rest = live.filter { asks.contains($0) } + live.filter { !asks.contains($0) }
            self.continuePaneClose()
        }
        for id in live {
            engineTab(for: id)?.evaluate(Self.wouldAskBeforeUnload) { answer in
                if (answer as? Bool) == true { asks.insert(id) }
                left -= 1
                if left == 0 { start() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { start() }
        return true
    }

    /// The next pane's page closes; one with unload handlers is waited for (`panePageClosed` / `stopPaneClose`).
    func continuePaneClose() {
        while var q = paneCloseQueue, !q.rest.isEmpty {
            let id = q.rest.removeFirst()
            q.current = id
            paneCloseQueue = q
            guard let page = engineTab(for: id), !page.isClosed else { continue }
            page.close()
            guard page.isClosed else { return }
            unloadPage(id)
        }
        guard let q = paneCloseQueue else { return }
        paneCloseQueue = nil
        if store.tab(q.focused) != nil { finishClosing(q.focused) }
    }

    /// A pane's page let the close through (after its question, if it asked).
    func panePageClosed(_ id: String) {
        unloadPage(id)
        continuePaneClose()
    }

    /// The person stayed on a pane: nothing more closes, and the split shows again with that pane focused (any pane
    /// that already closed loads again).
    func stopPaneClose(stayedOn id: String) {
        paneCloseQueue = nil
        if store.tab(id) != nil { show(id) }
    }

    /// The other panes of the pinned or Favorite split `tabID` is a pane of, whose pages close with it.
    func panesClosingWith(_ tabID: String) -> [String] {
        guard let s = store.splitItem(ofPane: store.tab(tabID)?.itemID) else { return [] }
        return store.paneTabs(ofSplitItem: s.id).map(\.id).filter { $0 != tabID }
    }

    /// Every pane away from its saved URL goes back to it.
    func resetPanes(of itemID: String) {
        for t in store.paneTabs(ofSplitItem: itemID) where store.isDrifted(t.id) {
            guard let saved = try? store.resetToSavedURL(t.id), let url = URL(string: saved) else { continue }
            if let page = engineTab(for: t.id) { engineWindow.load(url, in: page) }
        }
    }

    /// Deletes a pinned or Favorite split with its panes, closing their pages. ⌘Z restores it.
    func deleteItemSplit(_ itemID: String) {
        for t in store.paneTabs(ofSplitItem: itemID) { forgetPage(t.id, close: true) }
        try? store.deleteItem(itemID)
    }

    /// The menu of a pinned split's row or a Favorite split's tile; a segment's pane first, when it was opened over one.
    func itemSplitMenu(_ item: Item, pane: String?) -> NSMenu {
        let m = NSMenu()
        let isFav = item.isFavorite
        let tabs = store.paneTabs(ofSplitItem: item.id)
        let x = store.split(item.id)
        if let pane, let t = store.tab(pane), let p = store.item(t.itemID) {
            let current = engineTab(for: t.id)?.title
            let name = "“" + TextLimits.clip(current?.isEmpty == false ? current! : p.displayTitle) + "”"
            m.add("Copy Link") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.engineTab(for: t.id)?.url?.absoluteString ?? t.url, forType: .string)
                self.showToast("Copied Link")
            }
            if store.isDrifted(t.id) {
                m.add("Back to \(isFav ? "Favorite" : "Pinned") URL") { [weak self] in self?.resetToSaved(t.id, keepCurrent: false) }
                m.add("Replace \(name) with Current URL") { [weak self] in
                    guard let self, let page = self.engineTab(for: t.id), let u = page.url else { return }
                    try? self.store.replaceSavedURL(ofItem: p.id, with: u.absoluteString, title: page.title)
                }
            }
            m.add("Edit \(name)…") { [weak self] in self?.editPaneURL(p.id) }
            m.add("Separate \(name)") { [weak self] in self?.separatePinnedPane(t.id) }
            m.addItem(.separator())
        }
        let axis = item.splitLayout?.axis ?? .horizontal
        m.add(axis == .horizontal ? "Arrange Top to Bottom" : "Arrange Side by Side") { [weak self] in
            try? self?.store.setSplitAxis(item.id, axis == .horizontal ? .vertical : .horizontal)
        }
        if let x {
            m.add("Make Panes the Same Size") { [weak self] in
                guard let self else { return }
                if self.shownSplitID == x.id { self.splitContainer.equalize() }
                else { self.store.setSplitFractions(x.id, Array(repeating: 1, count: x.tabIDs.count)) }
            }
            if x.tabIDs.count == 2 { m.add("Swap Panes") { [weak self] in try? self?.store.movePane(x.id, from: 0, to: 1) } }
            if store.panes(ofSplitItem: item.id).count < Split.maxPanes {
                m.add("Add Split View", "⌃⇧+") { [weak self] in self?.newSplitView(axis: x.axis, anchor: x.focusedTabID ?? x.tabIDs.last) }
            }
        }
        if tabs.contains(where: { store.isDrifted($0.id) }) {
            m.add("Reset All Panes") { [weak self] in self?.resetPanes(of: item.id) }
        }
        m.addItem(.separator())
        m.add("Separate All Tabs") { [weak self] in self?.separateItemSplit(item.id) }
        if isFav {
            m.add("Remove from Favorites") { [weak self] in
                guard let self else { return }
                self.performDrop(.item(item.id), to: .today(spaceID: self.currentSpaceID, index: 0))
            }
        } else {
            m.add("Unpin") { [weak self] in
                guard let self else { return }
                self.performDrop(.item(item.id), to: .today(spaceID: self.currentSpaceID, index: 0))
            }
            m.add("Add to Favorites") { [weak self] in
                guard let self else { return }
                self.performDrop(.item(item.id), to: .favorites(profileID: self.store.profile(ofSpace: self.currentSpaceID).id, index: 99))
            }
            m.add("Duplicate") { [weak self] in _ = try? self?.store.duplicateItem(item.id) }
        }
        if !tabs.isEmpty {
            m.add("Close (keeps it \(isFav ? "in Favorites" : "pinned"))") { [weak self] in self?.closeItemSplit(item.id) }
        }
        m.add(isFav ? "Delete Favorite" : "Delete") { [weak self] in self?.deleteItemSplit(item.id) }
        return m
    }

    /// "Separate All Tabs" on a pinned or Favorite split; Favorites that can't take them all say so.
    func separateItemSplit(_ itemID: String) {
        let focused = shownSplitID == itemID ? shownTabID : nil
        do {
            try store.separateSplit(itemID)
            if let focused { show(focused) }
        } catch StoreError.favoritesFull {
            showToast("Favorites are full (12)")
        } catch {
            NSSound.beep()
        }
    }

    /// One pane becomes a pinned tab or Favorite of its own, just after the split.
    func separatePinnedPane(_ tabID: String) {
        let focused = shownTabID
        do {
            try store.removeFromSplit(tabID)
            if let focused, store.tab(focused) != nil { show(focused) }
        } catch StoreError.favoritesFull {
            showToast("Favorites are full (12)")
        } catch {
            NSSound.beep()
        }
    }

    /// A pane's saved URL (where "Back to pinned URL" goes) and name.
    func editPaneURL(_ paneID: String) {
        guard let pane = store.item(paneID) else { return }
        let alert = NSAlert()
        alert.messageText = "Edit Pane"
        alert.informativeText = "The page this pane goes back to."
        let name = NSTextField(string: pane.title ?? "")
        name.placeholderString = pane.pageTitle ?? "Name"
        let url = NSTextField(string: pane.savedURL ?? "")
        let stack = NSStackView(views: [name, url])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = url
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            if let u = URLRules.normalizeInput(url.stringValue) ?? (URL(string: url.stringValue) != nil ? url.stringValue : nil) {
                try? self.store.replaceSavedURL(ofItem: paneID, with: u)
            }
            try? self.store.renameItem(paneID, to: name.stringValue)
        }
    }
}
