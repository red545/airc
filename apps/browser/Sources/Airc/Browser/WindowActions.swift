// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

// User actions: menus, rename, pin, Favorites, Clear, drag and drop, clipboard, Space and profile
// management. Each one goes through SpacesStore so it persists and can sync later.

extension WindowController {
    var currentTab: LiveTab? { store.tab(shownTabID) }

    // MARK: Navigation (header buttons, ⌘[ ⌘] ⌘R)

    func goBack() { pages[shownTabID ?? ""]?.goBack() }
    func goForward() { pages[shownTabID ?? ""]?.goForward() }

    /// SB-1: ⌘-click on Back or Forward opens that page in a new tab in the background (Chrome, Arc); the page on
    /// screen stays.
    func openHistoryInBackground(offset: Int) {
        guard let page = pages[shownTabID ?? ""] else { return }
        let h = page.history
        guard let e = (offset < 0 ? h.back : h.forward).first(where: { $0.offset == offset }) else { return NSSound.beep() }
        _ = try? store.openTab(url: e.url, inSpace: currentSpaceID, background: true, activate: false,
                               title: e.title)
    }

    /// SB-1: the shown tab's history behind Back (or ahead, Forward), nearest first, as Chrome lists it: each page's
    /// title (or address); choosing one goes there. Nil when there's nothing.
    func historyMenu(forward: Bool) -> NSMenu? {
        guard let page = pages[shownTabID ?? ""] else { return nil }
        let entries = forward ? page.history.forward : page.history.back
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for e in entries.prefix(15) {
            let title = e.title.isEmpty ? URLRules.displayURL(e.url) : e.title
            menu.add(TextLimits.clip(title)) { [weak self, weak page] in
                guard let self, let page, self.pages[self.shownTabID ?? ""] === page else { return }
                page.go(offset: e.offset)
            }.toolTip = e.url
        }
        Telemetry.shared.record(.featureUsed(.historyMenu(forward ? .forward : .back)))
        return menu
    }

    func reloadOrStop() {
        guard let p = engineTab(for: shownTabID ?? "") else { return }
        if p.isLoading { p.stop() } else { p.reload() }
    }

    /// Opens what was typed. ⌘T always makes a new Today tab; ⌘L loads in place unless the tab is
    /// pinned or a Favorite, in which case a Today tab opens (SB-32).
    func navigate(to url: URL, newTab: Bool, typed: Bool = false) {
        let decision = newTab ? .openTodayTab : store.navigationDecision(forTab: shownTabID)
        if decision == .loadInPlace, let id = shownTabID, let page = engineTab(for: id) {
            if typed { markTyped(id) }
            store.updateTab(id, url: url.absoluteString)
            // The engine window may open it in another engine (a DRM service: `replace` brings the new page).
            engineWindow.load(url, in: page)
            engineTab(for: id)?.focus()
            return
        }
        guard let t = try? store.openTab(url: url.absoluteString, inSpace: currentSpaceID) else { return }
        if typed { markTyped(t.id) }
        show(t.id)
    }

    // MARK: Tabs

    func toggleMute(_ tabID: String) {
        guard let t = store.tab(tabID) else { return }
        let muted = !t.isMuted
        try? store.setMuted(tabID, muted)
        engineTab(for: tabID)?.isMuted = muted
        refreshRow(tabID)
    }

    /// "Back to pinned URL" (SB-31). With ⌘, the current page stays open as a new Today tab.
    func resetToSaved(_ tabID: String, keepCurrent: Bool) {
        guard let tab = store.tab(tabID) else { return }
        if keepCurrent {
            _ = try? store.openTab(url: tab.url, inSpace: currentSpaceID, background: true, activate: false,
                                   title: tab.title)
        }
        guard let saved = try? store.resetToSavedURL(tabID), let url = URL(string: saved) else { return }
        if let page = engineTab(for: tabID) { engineWindow.load(url, in: page) }
        if tabID != shownTabID { show(tabID) }
    }

    func togglePin() {
        guard let id = shownTabID else { return }
        try? store.togglePin(id, inSpace: currentSpaceID)
    }

    func addCurrentToFavorites() {
        guard let id = shownTabID else { return }
        performDrop(.tab(id), to: .favorites(profileID: store.profile(ofSpace: currentSpaceID).id, index: Int.max / 2))
    }

    /// SB-40: every Today tab but the one shown goes to the Archive, each page closing first (closeThenArchive).
    func clearToday() {
        guard archiveQueue == nil else { return }
        // The rows' tabs as shown; a split on screen stays whole (SV-1).
        let kept = visibleTabIDs
        let ids = store.todayRowTabs(ofSpace: currentSpaceID).map(\.id).filter { !kept.contains($0) }
        closeThenArchive(ids, reason: .clear, label: "Clear Today")
    }

    func toggleFolder(_ id: String) { try? store.toggleFolder(id) }

    func togglePinnedCollapsed(_ spaceID: String) {
        try? store.updateSpace(spaceID) { $0.pinnedCollapsed.toggle() }
    }

    /// The single drop handler (SB-35).
    func performDrop(_ source: DragSource, to destination: DropDestination) {
        if case .split = destination { return performSplitDrop(source, to: destination) }
        do {
            var dest = destination
            if case .favorites(let pid, let index) = destination {
                dest = .favorites(profileID: pid, index: min(index, store.favorites(ofProfile: pid).count))
            }
            let newFavorite = makesNewFavorite(source, dest)
            let reload = try store.move(source, to: dest)
            if newFavorite { Telemetry.shared.record(.featureUsed(.favoriteAdd)) }
            reloadPagesInNewProfile(reload)
        } catch StoreError.favoritesFull {
            showToast("Favorites are full (12)")
        } catch {
            NSSound.beep()
        }
    }

    /// SB-36: a dragged multi-selection, all of it at the drop, in one undo step.
    func performDrop(_ sources: [DragSource], to destination: DropDestination) {
        do {
            reloadPagesInNewProfile(try store.move(sources, to: destination))
            if case .split = destination, case .tab(let id)? = sources.first, store.split(containing: id) != nil { show(id) }
        } catch StoreError.favoritesFull {
            showToast("Favorites are full (12)")
        } catch {
            NSSound.beep()
        }
    }

    /// ⌥ at the drop of a multi-selection: a copy of each row there, in one undo step.
    func performCopy(_ sources: [DragSource], to destination: DropDestination) {
        do {
            try store.copy(sources, to: destination)
        } catch StoreError.favoritesFull {
            showToast("Favorites are full (12)")
        } catch {
            NSSound.beep()
        }
    }

    /// SB-36: what a right-click on a multi-selection offers, for every selected row at once.
    func selectionMenu(ids: [String], spaceID: String) -> NSMenu {
        let sources: [DragSource] = ids.compactMap { id in
            if store.item(id) != nil { return .item(id) }
            return store.tab(id) != nil ? .tab(id) : nil
        }
        let n = sources.count
        func url(_ s: DragSource) -> String? {
            switch s {
            case .item(let id):
                let t = store.liveTab(forItem: id)
                return t.flatMap { engineTab(for: $0.id)?.url?.absoluteString } ?? t?.url ?? store.item(id)?.savedURL
            case .tab(let id):
                return engineTab(for: id)?.url?.absoluteString ?? store.tab(id)?.url
            case .split:
                return nil
            }
        }
        let m = NSMenu()
        m.add("Copy \(n) Links") { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sources.compactMap(url).joined(separator: "\n"), forType: .string)
            self?.showToast("Copied \(n) Links")
        }
        m.add("New Folder with \(n) Items") { [weak self] in
            guard let self else { return }
            if let f = try? self.store.createFolder(inSpace: spaceID, containing: sources) {
                self.pageView(for: spaceID)?.clearSelection()
                self.renameItemFromMenu(f.id)
            }
        }
        let move = NSMenuItem(title: "Move \(n) to Space", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in store.orderedSpaces where s.id != spaceID {
            sub.add(s.iconLabel.isEmpty ? s.name : "\(s.iconLabel)  \(s.name)") { [weak self] in
                guard let self else { return }
                for (k, src) in sources.enumerated() {
                    // Pinned rows stay pinned, Today tabs stay in Today, in the same order.
                    if case .item = src {
                        self.performDrop(src, to: .pinned(spaceID: s.id, parentID: nil, index: self.store.pinnedRoots(ofSpace: s.id).count))
                    } else {
                        self.performDrop(src, to: .today(spaceID: s.id, index: k))
                    }
                }
                self.pageView(for: spaceID)?.clearSelection()
            }
        }
        move.submenu = sub
        move.isEnabled = !sub.items.isEmpty
        m.addItem(move)
        m.addItem(.separator())
        m.add("Archive \(n) Tabs") { [weak self] in
            guard let self else { return }
            for src in sources {
                switch src {
                case .tab(let id): self.closeTab(id)
                case .item(let id): if let t = self.store.liveTab(forItem: id) { self.closeTab(t.id) }
                case .split(let id): self.store.split(id)?.tabIDs.forEach { self.closeTab($0) }
                }
            }
            self.pageView(for: spaceID)?.clearSelection()
        }
        return m
    }

    /// ⌥-drag (Arc): a copy lands at the destination; the dragged row stays.
    func performCopy(_ source: DragSource, to destination: DropDestination) {
        do {
            try store.copy(source, to: destination)
        } catch StoreError.favoritesFull {
            showToast("Favorites are full (12)")
        } catch {
            NSSound.beep()
        }
    }

    func selectAdjacentTab(_ offset: Int) {
        guard let e = store.adjacentEntry(to: shownTabID, offset: offset, inSpace: currentSpaceID) else { return }
        activate(entry: e)
    }

    func selectTab(number n: Int) {
        guard let e = store.commandNumberTarget(n, inSpace: currentSpaceID) else { return }
        activate(entry: e)
    }

    /// ⌃Tab: the most recently used other tab in this Space.
    func selectLastTab() {
        let candidates = store.sidebarEntries(ofSpace: currentSpaceID, skippingCollapsed: false)
            .compactMap(\.liveTab).filter { $0.id != shownTabID }
        if let t = candidates.max(by: { $0.lastActiveAt < $1.lastActiveAt }) { show(t.id) }
    }

    // MARK: Clipboard (⇧⌘C, ⌥⇧⌘C)

    func copyURL() {
        guard let t = currentTab else { return }
        let url = engineTab(for: t.id)?.url?.absoluteString ?? t.url
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        showToast("Copied Current URL")
    }

    func copyURLMarkdown() {
        guard let t = currentTab else { return }
        let page = engineTab(for: t.id)
        let md = URLRules.markdownLink(title: page?.title ?? t.title, url: page?.url?.absoluteString ?? t.url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        showToast("Copied URL as Markdown")
    }

    // MARK: Sign in to Google (SP-12)

    func showsSignInCard(spaceID: String) -> Bool {
        store.space(spaceID).map { showsSignInCard(space: $0) } ?? false
    }

    /// The same for a Space value, which may not be in the store yet (the spare page drawn ahead for New Space).
    func showsSignInCard(space s: Space) -> Bool {
        guard let p = store.profile(s.profileID), !p.isDefault, p.googleAccount == nil, !dismissedSignIn(p.id) else { return false }
        return store.todayTabs(ofSpace: s.id).isEmpty && store.pinnedRoots(ofSpace: s.id).isEmpty
    }

    private func dismissedSignIn(_ profileID: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "AircDismissedSignIn") ?? []).contains(profileID)
    }

    func dismissSignInCard(spaceID: String) {
        guard let pid = store.space(spaceID)?.profileID else { return }
        var list = UserDefaults.standard.stringArray(forKey: "AircDismissedSignIn") ?? []
        list.append(pid)
        UserDefaults.standard.set(list, forKey: "AircDismissedSignIn")
        scheduleReload()
    }

    func signInToGoogle(spaceID: String) {
        if spaceID != currentSpaceID { switchToSpace(spaceID, animated: true) }
        navigate(to: URL(string: "https://accounts.google.com/")!, newTab: true)
    }

    // MARK: Rename in place

    func beginRename(itemID: String, in row: NSView, titleFrame: NSRect) {
        guard let item = store.item(itemID) else { return }
        InlineEditor.begin(in: row, frame: titleFrame, text: item.displayTitle, font: item.kind == .folder ? AircFont.row.weight(.semibold).appFont : AircFont.row.appFont) { [weak self] text in
            try? self?.store.renameItem(itemID, to: text)
        }
    }

    func beginRenameSpace(_ spaceID: String, in row: NSView, titleFrame: NSRect) {
        guard let s = store.space(spaceID) else { return }
        InlineEditor.begin(in: row, frame: titleFrame, text: s.name, font: AircFont.spaceName.appFont) { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            try? self?.store.updateSpace(spaceID) { $0.name = name }
        }
    }

    func renameCurrentSpace() {
        guard let page = pageView(for: currentSpaceID) else { return }
        beginRenameSpace(currentSpaceID, in: page.header, titleFrame: NSRect(x: AircMetrics.SpaceHeader.nameX, y: 11,
                                                                             width: page.header.bounds.width - 80, height: 18))
    }

    // MARK: Menus

    func menu(for entry: SidebarEntry) -> NSMenu {
        if let item = entry.item, item.kind == .split { return itemSplitMenu(item, pane: nil) }   // SV-2
        let m = NSMenu()
        switch entry {
        case .today(let t):
            m.add("Copy Link", "⇧⌘C") { [weak self] in self?.copyLink(of: t.id) }
            m.add("Rename…") { [weak self] in self?.renameTodayTab(t.id) }
            m.add(t.isMuted ? "Unmute" : "Mute") { [weak self] in self?.toggleMute(t.id) }
            m.add("Add Split View", "⌃⇧+") { [weak self] in self?.newSplitView(anchor: t.id) }
            m.add("Duplicate") { [weak self] in _ = try? self?.store.duplicateTab(t.id) }
            m.addItem(moveToMenu(tabID: t.id))
            m.addItem(.separator())
            m.add("Pin Tab", "⌘D") { [weak self] in
                guard let self else { return }
                try? self.store.togglePin(t.id, inSpace: self.currentSpaceID)
            }
            m.add("Add to Favorites") { [weak self] in
                guard let self else { return }
                self.performDrop(.tab(t.id), to: .favorites(profileID: t.profileID, index: 99))
            }
            m.addItem(.separator())
            m.add("Archive Tab", "⌘W") { [weak self] in self?.closeTab(t.id) }
            m.add("Archive Tabs Below") { [weak self] in self?.archiveBelow(t.id) }
        case .pinned(let item, _, let t), .favorite(let item, let t):
            let isFav = item.isFavorite
            m.add("Copy Link") { [weak self] in
                let url = t.flatMap { self?.engineTab(for: $0.id)?.url?.absoluteString } ?? t?.url ?? item.savedURL ?? ""
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                self?.showToast("Copied Link")
            }
            if !isFav { m.add("Rename…") { [weak self] in self?.renameItemFromMenu(item.id) } }
            let pinnedURL = NSMenuItem(title: isFav ? "Favorite URL" : "Pinned URL", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.add("Replace with Current URL") { [weak self] in
                guard let self, let t, let page = self.engineTab(for: t.id), let u = page.url else { return }
                try? self.store.replaceSavedURL(ofItem: item.id, with: u.absoluteString, title: page.title)
            }.isEnabled = t.map { store.isDrifted($0.id) } ?? false
            sub.add("Edit…") { [weak self] in self?.editSavedURL(item.id) }
            pinnedURL.submenu = sub
            m.addItem(pinnedURL)
            if t != nil, store.isDrifted(t!.id) {
                m.add("Back to Pinned URL") { [weak self] in self?.resetToSaved(t!.id, keepCurrent: false) }
            }
            if !isFav { m.add("Duplicate") { [weak self] in _ = try? self?.store.duplicateItem(item.id) } }
            m.addItem(.separator())
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
            }
            if let t { m.add("Close (keeps it \(isFav ? "in Favorites" : "pinned"))") { [weak self] in self?.closeTab(t.id) } }
            m.add(isFav ? "Delete Favorite" : "Delete") { [weak self] in
                guard let self else { return }
                if let t { self.forgetPage(t.id, close: true) }
                try? self.store.deleteItem(item.id)
            }
        case .split:
            return menu(for: entry, pane: nil)
        case .folder(let item, _):
            m.add("Rename…") { [weak self] in self?.renameItemFromMenu(item.id) }
            m.add("Change Icon…") { [weak self] in self?.changeFolderIcon(item.id) }
            m.add("Copy All Links") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.store.allLinks(inFolder: item.id).joined(separator: "\n"), forType: .string)
                self.showToast("Copied \(self.store.allLinks(inFolder: item.id).count) Links")
            }
            m.add("New Folder Inside") { [weak self] in
                guard let self else { return }
                _ = try? self.store.createFolder(inSpace: self.currentSpaceID, parentID: item.id)
            }
            m.addItem(.separator())
            m.add("Delete Folder") { [weak self] in self?.deleteItemWithPages(item.id) }
        }
        return m
    }

    func spaceMenu(spaceID: String) -> NSMenu {
        let m = NSMenu()
        guard let space = store.space(spaceID) else { return m }
        m.add("Change Space Icon…") { [weak self] in self?.changeSpaceIcon(spaceID) }
        m.add("Rename Space…") { [weak self] in
            guard let self else { return }
            if spaceID != self.currentSpaceID { self.switchToSpace(spaceID, animated: true) }
            self.renameCurrentSpace()
        }
        m.add("Edit Theme Color…") { [weak self] in self?.editTheme(spaceID) }
        let profileItem = NSMenuItem(title: "Set Profile", action: nil, keyEquivalent: "")
        profileItem.submenu = setProfileMenu(spaceID: spaceID, current: space.profileID)
        m.addItem(profileItem)
        m.addItem(.separator())
        m.add("New Folder…") { [weak self] in _ = try? self?.store.createFolder(inSpace: spaceID) }
        m.addItem(.separator())
        m.add("Manage Spaces…") { [weak self] in self?.showStub("Manage Spaces") }
        m.addItem(.separator())
        m.add("Delete Space") { [weak self] in self?.deleteSpace(spaceID) }.isEnabled = store.state.spaces.count > 1
        return m
    }

    /// SP-13, SP-15: Space menu → Set Profile › and the Space header's profile indicator. Profiles with avatars, ✓ on
    /// this Space's, then New Profile… (Arc's two-step card with this Space ticked).
    func setProfileMenu(spaceID: String, current: String) -> NSMenu {
        let sub = NSMenu()
        for p in store.orderedProfiles {
            let item = sub.add(p.name) { [weak self] in self?.changeProfile(ofSpace: spaceID, to: p.id) }
            item.image = ProfileAvatarImage.image(p, size: 18)
            if #available(macOS 14.4, *), let account = p.googleAccount { item.subtitle = account }
            item.state = p.id == current ? .on : .off
        }
        sub.addItem(.separator())
        let new = sub.add("New Profile…") { [weak self] in self?.openCreateProfile(forSpace: spaceID) }
        new.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        return sub
    }

    func plusMenu() -> NSMenu {
        let m = NSMenu()
        m.add("New Space…") { [weak self] in self?.openNewSpacePanel() }
        m.add("New Folder…") { [weak self] in
            guard let self else { return }
            _ = try? self.store.createFolder(inSpace: self.currentSpaceID)
        }
        m.add("New Tab", "⌘T") { [weak self] in self?.openCommandBar(mode: .newTab) }
        // SV-1 (Arc's "New Right Split" / "New Bottom Split").
        m.add("New Split View", "⌃⇧+") { [weak self] in self?.newSplitView(axis: .horizontal) }
        m.add("New Bottom Split") { [weak self] in self?.newSplitView(axis: .vertical) }
        return m
    }

    private func moveToMenu(tabID: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in store.orderedSpaces where s.id != store.tab(tabID)?.spaceID {
            sub.add(s.iconLabel + "  " + s.name) { [weak self] in self?.moveTab(tabID, to: s.id) }
        }
        sub.addItem(.separator())
        sub.add("New Space…") { [weak self] in self?.openNewSpacePanel() }
        item.submenu = sub
        return item
    }

    func moveTab(_ tabID: String, to spaceID: String) {
        guard let tab = store.tab(tabID), let target = store.space(spaceID) else { return }
        let crossProfile = tab.profileID != target.profileID
        let go = {
            let wasShown = tabID == self.shownTabID
            let next = wasShown ? self.store.tabToSelect(afterClosing: tabID, inSpace: self.currentSpaceID) : nil
            guard let reload = try? self.store.moveTab(tabID, toSpace: spaceID) else { return }
            if reload { self.forgetPage(tabID, close: true) }
            if wasShown { if let next { self.show(next.id) } else { self.showEmpty() } }
        }
        if crossProfile {
            confirmInterProfileMove(title: "Move this tab to “\(target.name)”?",
                                    message: "This page reloads with the other Profile’s logins and data, so it may look different.\n\nThere’s no undo.",
                                    confirm: "Move it", then: go)
        } else {
            go()
        }
    }

    func archiveBelow(_ tabID: String) {
        let today = store.todayRowTabs(ofSpace: currentSpaceID)
        guard archiveQueue == nil, let i = today.firstIndex(where: { $0.id == tabID }) else { return }
        let kept = visibleTabIDs
        closeThenArchive(today[(i + 1)...].map(\.id).filter { !kept.contains($0) }, reason: .manual, label: "Archive Tabs Below")
    }

    private func copyLink(of tabID: String) {
        guard let t = store.tab(tabID) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engineTab(for: tabID)?.url?.absoluteString ?? t.url, forType: .string)
        showToast("Copied Link")
    }

    private func renameTodayTab(_ tabID: String) {
        // A Today tab gets a name by pinning it in Arc; we keep it simple: pin, then rename.
        try? store.togglePin(tabID, inSpace: currentSpaceID)
        if let itemID = store.tab(tabID)?.itemID {
            DispatchQueue.main.async { self.renameItemFromMenu(itemID) }
        }
    }

    private func renameItemFromMenu(_ itemID: String) {
        guard let page = pageView(for: currentSpaceID) else { return }
        page.layoutSubtreeIfNeeded()
        for v in page.list.subviews {
            if let r = v as? TabRowView, r.entry?.item?.id == itemID {
                beginRename(itemID: itemID, in: r, titleFrame: r.titleField.frame)
                return
            }
            if let f = v as? FolderRowView, f.item?.id == itemID {
                beginRename(itemID: itemID, in: f, titleFrame: f.titleField.frame)
                return
            }
        }
    }

    private func editSavedURL(_ itemID: String) {
        guard let item = store.item(itemID) else { return }
        let alert = NSAlert()
        alert.messageText = "Edit \(item.isFavorite ? "Favorite" : "Pinned Tab")"
        alert.informativeText = "The page this tab goes back to."
        let name = NSTextField(string: item.title ?? "")
        name.placeholderString = item.pageTitle ?? "Name"
        let url = NSTextField(string: item.savedURL ?? "")
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
                try? self.store.replaceSavedURL(ofItem: itemID, with: u)
            }
            try? self.store.renameItem(itemID, to: name.stringValue)
        }
    }

    private func deleteItemWithPages(_ itemID: String) {
        var ids: [String] = []
        func collect(_ id: String) {
            if let t = store.liveTab(forItem: id) { ids.append(t.id) }
            for c in store.state.items.values where c.parentID == id { collect(c.id) }
        }
        collect(itemID)
        ids.forEach { forgetPage($0, close: true) }
        try? store.deleteItem(itemID)
    }

    /// Drops the engine page of a tab (closing it), showing another tab if it was in front.
    func forgetPage(_ tabID: String, close: Bool = false) {
        let wasShown = tabID == shownTabID
        if close, let p = engineTab(for: tabID) { p.delegate = nil; p.close() }
        removePageMapping(tabID)
        if wasShown {
            if let t = store.lastActiveTab(ofSpace: currentSpaceID), t.id != tabID { show(t.id) } else { showEmpty() }
        }
    }

    // MARK: Spaces and profiles

    func deleteSpace(_ spaceID: String) {
        guard let s = store.space(spaceID), store.state.spaces.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(s.name)”?"
        alert.informativeText = "This deletes the Space and closes its tabs. Its Today tabs go to the Archive."
        alert.addButton(withTitle: "Delete Space")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            let tabs = self.store.state.tabs.values.filter { $0.spaceID == spaceID }.map(\.id)
            let wasCurrent = spaceID == self.currentSpaceID
            do { try self.store.deleteSpace(spaceID) } catch { return }
            tabs.forEach { self.forgetPage($0, close: true) }
            if wasCurrent, let sid = self.store.windowState.selectedSpaceID {
                self.reloadAll(animated: false)
                self.switchToSpace(sid, animated: true)
            }
            self.showToast("Space deleted! Use ⌘Z to undo.")
        }
    }

    /// SP-13 with Arc's confirm ("Don't ask again").
    func changeProfile(ofSpace spaceID: String, to profileID: String) {
        guard let s = store.space(spaceID), s.profileID != profileID else { return }
        let go = {
            guard let reload = try? self.store.setProfile(ofSpace: spaceID, to: profileID) else { return }
            self.reloadPagesInNewProfile(reload)
            if spaceID == self.currentSpaceID, let p = self.profiles.engineProfile(for: profileID) {
                self.engineWindow.activeProfile = p
            }
        }
        if store.state.tabs.values.contains(where: { $0.spaceID == spaceID }) {
            confirmInterProfileMove(
                title: "Change the Profile of “\(s.name)”?",
                message: "Your \(s.name) Space will use the other Profile’s logins and data, so some sites may sign you out, the Favorites at the top change, and extensions may need installing again.\n\nThere’s no undo.",
                confirm: "Change Profile", then: go)
        } else {
            go()
        }
    }

    private func confirmInterProfileMove(title: String, message: String, confirm: String, then go: @escaping () -> Void) {
        let key = "AircSkipInterProfileConfirm"
        if UserDefaults.standard.bool(forKey: key) { return go() }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: key) }
            go()
        }
    }

    func changeSpaceIcon(_ spaceID: String) {
        guard let page = pageView(for: spaceID) else { return }
        if spaceID != currentSpaceID { switchToSpace(spaceID, animated: true) }
        let picker = EmojiPicker(onPick: { [weak self] e in
            try? self?.store.updateSpace(spaceID) { $0.icon = e.map(SpaceIcon.emoji) }
        })
        Popover.show(picker, size: NSSize(width: 273, height: 273), relativeTo: page.header.bounds, of: page.header, edge: .maxX)
    }

    func changeFolderIcon(_ itemID: String) {
        guard let page = pageView(for: currentSpaceID) else { return }
        let anchor = page.list.subviews.first { ($0 as? FolderRowView)?.item?.id == itemID } ?? page.header
        let picker = EmojiPicker(onPick: { [weak self] e in try? self?.store.setItemIcon(itemID, to: e) })
        Popover.show(picker, size: NSSize(width: 273, height: 273), relativeTo: anchor.bounds, of: anchor, edge: .maxX)
    }

    /// Edit Theme Color… (TH-1): swatches, intensity, grain and appearance; recolours live.
    func editTheme(_ spaceID: String) {
        guard let s = store.space(spaceID), let page = pageView(for: spaceID) else { return }
        if spaceID != currentSpaceID { switchToSpace(spaceID, animated: true) }
        showThemePicker(theme: s.theme, relativeTo: page.header.bounds, of: page.header) { [weak self] theme in
            AppTelemetry.shared.record(.themeChanged, atMostEvery: 60)
            try? self?.store.updateSpace(spaceID) { $0.theme = theme }
        }
    }

    // MARK: Stubs for the next pass

    func showLibrary() { toggleLibrary() }
    func showStub(_ name: String) { showToast("\(name) arrives in the next pass") }
}

extension Space {
    var iconLabel: String {
        switch icon {
        case .emoji(let e)?: e
        case .symbol?: "◆"
        case nil: "●"
        }
    }
}

// MARK: - Small AppKit helpers

final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, _ shortcutHint: String? = nil, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        item.target = item
        item.handler = handler
        if let shortcutHint {
            // Shown as a hint; the real shortcut lives in the main menu.
            item.toolTip = shortcutHint
        }
        addItem(item)
        return item
    }
}

/// Inline rename: a field over the title; ↩ or clicking away saves, Esc cancels (Arc ref §2.4).
enum InlineEditor {
    final class Field: NSTextField, NSTextFieldDelegate {
        var onCommit: ((String) -> Void)?
        var cancelled = false
        func controlTextDidEndEditing(_ obj: Notification) {
            if !cancelled { onCommit?(stringValue) }
            onCommit = nil
            removeFromSuperview()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                cancelled = true
                window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }

    static func begin(in view: NSView, frame: NSRect, text: String, font: NSFont, commit: @escaping (String) -> Void) {
        let f = Field(string: text)
        f.font = font
        f.isBordered = false
        f.focusRingType = .none
        f.drawsBackground = true
        f.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        f.wantsLayer = true
        f.layer?.cornerRadius = 4
        f.frame = frame.insetBy(dx: -3, dy: -2)
        f.delegate = f
        f.onCommit = commit
        view.addSubview(f)
        view.window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }
}

/// Shows a SwiftUI view in a transient popover.
enum Popover {
    static func show<V: View>(_ content: V, size: NSSize, relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let host = NSHostingController(rootView: content.frame(width: size.width, height: size.height))
        p.contentViewController = host
        p.contentSize = size
        p.show(relativeTo: rect, of: view, preferredEdge: edge)
    }
}
