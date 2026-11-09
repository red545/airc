// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// SB-36: what a sidebar multi-selection does (⌘- and ⇧-click rows, SpacePageView.select): its context menu, and ⌘W,
/// Delete, ⇧⌘C, ⌘D and Esc while it's there. Each action is one step for ⌘Z; the store does the work (AircKit's
/// BulkActions.swift), and the selection ends after it.
extension WindowController {
    /// The current Space's selection, if any rows are selected (entry IDs, in display order) and the sidebar still has
    /// the keyboard. Once a page, the Command Bar or a field has it (⌃Tab, ⌘1–9, ⌘T…), ⌘W, ⌘D and ⇧⌘C act on that
    /// again, not on rows still drawn as selected.
    var sidebarSelection: (page: SpacePageView, ids: [String])? {
        guard let page = pageView(for: currentSpaceID), !page.selection.isEmpty, window.firstResponder === page else { return nil }
        return (page, page.selection)
    }

    /// The store's sources for selected rows: an item (pinned tab, pinned split, folder, Favorite), a Today split, or a
    /// Today tab.
    func selectionSources(_ ids: [String]) -> [DragSource] {
        ids.compactMap { id in
            if store.item(id) != nil { return .item(id) }
            if store.state.splits[id] != nil { return .split(id) }
            return store.tab(id) != nil ? .tab(id) : nil
        }
    }

    /// The keys a selection takes from the key monitor, before the page or the menus (the sidebar has the keyboard while
    /// rows are selected): Esc clears it, Delete or Forward Delete archives it. True when the key was used.
    func handleSelectionKey(_ event: NSEvent) -> Bool {
        guard let (page, ids) = sidebarSelection,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 53: page.clearSelection()
        case 51, 117: archiveSelected(ids, spaceID: page.spaceID)
        default: return false
        }
        return true
    }

    #if AIRC_TESTING
    /// The multiselect check's own pasteboard for Copy Links (never the owner's clipboard).
    static var selectionTestPasteboard: NSPasteboard?
    #endif

    // MARK: The menu

    /// Right-click on a selected row (with more than one selected): every action at once, for all of them.
    func selectionMenu(ids: [String], spaceID: String) -> NSMenu {
        let sources = selectionSources(ids)
        let n = sources.count
        let hasFolder = sources.contains { if case .item(let id) = $0 { return store.item(id)?.kind == .folder }; return false }
        let noun = hasFolder ? (n == 1 ? "Item" : "Items") : (n == 1 ? "Tab" : "Tabs")
        let m = NSMenu()
        m.add("Copy \(n) Links", "⇧⌘C") { [weak self] in self?.copySelectedLinks(ids) }
        addSelectionLinkItems(to: m, ids: ids)   // ⌥ Markdown, Share › (P01a: Browser/SelectionShare.swift)
        m.add("Duplicate \(n) \(noun)") { [weak self] in self?.duplicateSelected(ids, spaceID: spaceID) }
        if store.splitCandidates(sources) != nil {
            m.add("Open in Split View") { [weak self] in self?.splitSelected(ids, spaceID: spaceID) }
        }
        m.addItem(.separator())
        m.add((store.allPinned(sources) ? "Unpin" : "Pin") + " \(n) \(noun)", "⌘D") { [weak self] in self?.pinSelected(ids, spaceID: spaceID) }
        m.add("New Folder with \(n) \(noun)") { [weak self] in self?.newFolderWithSelected(ids, spaceID: spaceID) }
        m.addItem(addToFolderMenu(ids: ids, spaceID: spaceID))
        m.addItem(moveToSpaceMenu(ids: ids, spaceID: spaceID))
        m.addItem(.separator())
        m.add("Close \(n) \(noun)", "⌘W") { [weak self] in self?.closeSelected(ids, spaceID: spaceID) }
        m.add("Archive \(n) \(noun)", "⌫") { [weak self] in self?.archiveSelected(ids, spaceID: spaceID) }
        return m
    }

    /// "Add to Folder ›": this Space's folders, nested ones indented, but not the selected ones or folders inside them.
    private func addToFolderMenu(ids: [String], spaceID: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let selected = Set(ids)
        func walk(_ parent: String?, depth: Int) {
            for f in store.children(of: .pinned(spaceID: spaceID), parent: parent) where f.kind == .folder && !selected.contains(f.id) {
                let row = sub.add((f.icon ?? "").isEmpty ? f.displayTitle : "\(f.icon!)  \(f.displayTitle)") { [weak self] in
                    self?.addSelected(ids, toFolder: f.id, spaceID: spaceID)
                }
                row.indentationLevel = depth
                walk(f.id, depth: depth + 1)
            }
        }
        walk(nil, depth: 0)
        item.submenu = sub
        item.isEnabled = !sub.items.isEmpty
        return item
    }

    private func moveToSpaceMenu(ids: [String], spaceID: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in store.orderedSpaces where s.id != spaceID {
            sub.add(s.iconLabel.isEmpty ? s.name : "\(s.iconLabel)  \(s.name)") { [weak self] in self?.moveSelected(ids, from: spaceID, to: s.id) }
        }
        item.submenu = sub
        item.isEnabled = !sub.items.isEmpty
        return item
    }

    // MARK: The actions

    /// ⌘W, "Close N Tabs": every selected row's page closes first, as ⌘W's does; then, in one undo step, the Today tabs
    /// go to the Archive and the pinned ones unload, keeping their rows. A page that asks "Leave site?" closes its tab on
    /// its own once the person leaves.
    func closeSelected(_ ids: [String], spaceID: String) {
        pageView(for: spaceID)?.clearSelection()
        // SV-2: a pinned or Favorite split's panes ask in turn; one the person stays on keeps the whole split.
        askSplitPanesFirst(ids) { [weak self] ids in self?.closeSelectedNow(ids) }
    }

    private func closeSelectedNow(_ ids: [String]) {
        let sources = selectionSources(ids)
        closePagesThen(store.liveTabs(of: sources).map(\.id)) { [weak self] closed in
            guard let self else { return }
            let next = self.nextTab(afterClosing: closed)
            if let shown = self.shownTabID, closed.contains(shown) { self.bulkClosedShown = shown }
            guard let gone = try? self.store.closeTabs(sources, only: closed), !gone.isEmpty else { return }
            self.finishBulk(gone, next: next)
        }
    }

    /// The pages of `tabs` close, as ⌘W's do; `then` runs once with the tabs whose page has closed, so they leave in one
    /// undo step: at once if every page closed at once, else when the last one has (Chromium closes a page a moment
    /// later), or after `bulkCloseWait`. A page still open then asked "Leave site?": its tab closes on its own once the
    /// person leaves (`finishClosing`), or stays.
    private func closePagesThen(_ tabs: [String], _ then: @escaping (Set<String>) -> Void) {
        bulkClose?.flush()
        let closed = closePages(tabs)
        let pending = Set(tabs).subtracting(closed).filter { closingTabs.contains($0) }
        guard !pending.isEmpty else { return then(closed) }
        let group = BulkClose(pending: pending, closed: closed) { [weak self] closed in
            self?.bulkClose = nil
            then(closed)
        }
        bulkClose = group
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bulkCloseWait) { [weak group] in group?.flush() }
    }

    static let bulkCloseWait: TimeInterval = 1

    /// Delete, "Archive N Tabs": the pages close first; then, in one undo step, every selected row goes to the Archive,
    /// pinned ones and folders (with what's in them) leaving the sidebar. A row whose page asks "Leave site?" isn't
    /// archived with the rest; it closes on its own once the person leaves.
    func archiveSelected(_ ids: [String], spaceID: String) {
        pageView(for: spaceID)?.clearSelection()
        askSplitPanesFirst(ids) { [weak self] ids in self?.archiveSelectedNow(ids) }
    }

    private func archiveSelectedNow(_ ids: [String]) {
        let sources = selectionSources(ids)
        closePagesThen(store.liveTabs(of: sources).map(\.id)) { [weak self] closed in
            guard let self else { return }
            // A row stays if any of its pages is still open (it asked).
            let ready = sources.filter { self.store.liveTabs(of: [$0]).allSatisfy { closed.contains($0.id) } }
            guard !ready.isEmpty else { return }
            let next = self.nextTab(afterClosing: closed)
            if let shown = self.shownTabID, closed.contains(shown) { self.bulkClosedShown = shown }
            guard let gone = try? self.store.archive(ready) else { return }
            self.finishBulk(gone, next: next)
        }
    }

    /// After a bulk close or archive: the pages are dropped; if the tab on screen went, the next free one shows.
    private func finishBulk(_ gone: [String], next: String?) {
        let shown = shownTabID
        gone.forEach(dropPage)
        if let shown, store.tab(shown) == nil || gone.contains(shown) {
            if let next, store.tab(next) != nil { show(next, takeOver: false) } else { showEmpty() }
        }
    }

    /// The tab to show if the one on screen is among `closing`: the next one below it in the sidebar that isn't closing
    /// and no other window shows, else the nearest above.
    private func nextTab(afterClosing closing: Set<String>) -> String? {
        guard let shown = shownTabID, closing.contains(shown) else { return nil }
        let live = store.sidebarEntries(ofSpace: currentSpaceID, skippingCollapsed: false).compactMap(\.liveTab)
        let free = { (t: LiveTab) in !closing.contains(t.id) && self.app?.window(showing: t.id, except: self) == nil }
        guard let i = live.firstIndex(where: { $0.id == shown }) else { return live.first(where: free)?.id }
        return (live[(i + 1)...].first(where: free) ?? live[..<i].reversed().first(where: free))?.id
    }

    /// ⇧⌘C, "Copy N Links": every selected row's address, one per line (a folder's links, nested ones too).
    func copySelectedLinks(_ ids: [String]) {
        let links = store.links(of: selectionSources(ids)) { [weak self] t in self?.engineTab(for: t.id)?.url?.absoluteString }
        guard !links.isEmpty else { return NSSound.beep() }
        var pasteboard = NSPasteboard.general
        #if AIRC_TESTING
        if let p = Self.selectionTestPasteboard { pasteboard = p }
        #endif
        pasteboard.clearContents()
        pasteboard.setString(links.joined(separator: "\n"), forType: .string)
        showToast(links.count == 1 ? "Copied Link" : "Copied \(links.count) Links")
    }

    /// ⌘D, "Pin N Tabs" / "Unpin N Tabs".
    func pinSelected(_ ids: [String], spaceID: String) {
        pageView(for: spaceID)?.clearSelection()
        do { reloadPagesInNewProfile(try store.togglePin(selectionSources(ids), inSpace: spaceID)) } catch { NSSound.beep() }
    }

    func duplicateSelected(_ ids: [String], spaceID: String) {
        pageView(for: spaceID)?.clearSelection()
        do { try store.duplicate(selectionSources(ids)) } catch { NSSound.beep() }
    }

    /// "New Folder with N Tabs": the folder holds them in order, and its name is ready to type.
    func newFolderWithSelected(_ ids: [String], spaceID: String) {
        pageView(for: spaceID)?.clearSelection()
        guard let f = try? store.newFolder(with: selectionSources(ids), inSpace: spaceID) else { return NSSound.beep() }
        if spaceID == currentSpaceID { DispatchQueue.main.async { self.renameItemFromMenu(f.id) } }
    }

    func addSelected(_ ids: [String], toFolder folderID: String, spaceID: String) {
        pageView(for: spaceID)?.clearSelection()
        do {
            if store.item(folderID)?.isCollapsed == true { try store.toggleFolder(folderID) }
            reloadPagesInNewProfile(try store.move(selectionSources(ids), intoFolder: folderID))
        } catch { NSSound.beep() }
    }

    /// "Move to Space ›": pinned rows stay pinned there, Today rows go to the top of its Today, in order. Into another
    /// profile's Space the pages reload with its logins, so it asks first (as one tab's Move to does).
    func moveSelected(_ ids: [String], from spaceID: String, to target: String) {
        guard let space = store.space(target) else { return }
        let sources = selectionSources(ids)
        let tabs = store.liveTabs(of: sources).map(\.id)
        let go = { [weak self] in
            guard let self else { return }
            self.pageView(for: spaceID)?.clearSelection()
            let moving = Set(tabs)
            let next = self.nextTab(afterClosing: moving)
            let shown = self.shownTabID
            do {
                self.reloadPagesInNewProfile(try self.store.move(sources, toSpace: target))
            } catch { return NSSound.beep() }
            if let shown, moving.contains(shown), spaceID == self.currentSpaceID {
                if let next { self.show(next) } else { self.showEmpty() }
            }
        }
        if store.profile(ofSpace: spaceID).id != space.profileID, !tabs.isEmpty {
            confirmInterProfileMove(title: "Move \(sources.count) tabs to “\(space.name)”?",
                                    message: "Their pages reload with the other Profile’s logins and data, so they may look different.",
                                    confirm: "Move them", then: go)
        } else {
            go()
        }
    }

    /// "Open in Split View" with 2–4 tab rows: their pages side by side, in the order selected.
    func splitSelected(_ ids: [String], spaceID: String) {
        pageView(for: spaceID)?.clearSelection()
        do {
            let x = try store.openInSplit(selectionSources(ids), inSpace: spaceID)
            Telemetry.shared.record(.featureUsed(.splitCreate(panes: x.tabIDs.count)))
            if spaceID != currentSpaceID { switchToSpace(spaceID, animated: true) }
            show(x.focusedTabID ?? x.tabIDs[0])
        } catch StoreError.splitFull {
            showToast(Self.splitFullMessage)
        } catch {
            NSSound.beep()
        }
    }

    // MARK: Dragged onto another window's sidebar

    /// SB-35 with SB-36: a multi-selection dropped on another browser window's sidebar lands where its line showed, in
    /// order, in one undo step; that window comes to the front and shows the first of them (its page moves there
    /// live). Onto that window's page there's nothing to do (one tab only), and nowhere at all it doesn't open a window.
    func drop(_ sources: [DragSource], into other: WindowController, at destination: DropDestination?) {
        guard let destination, let app else { return }
        let tabs = store.liveTabs(of: sources).map(\.id)
        performDrop(sources, to: destination)
        let sid: String? = switch destination {
        case .pinned(let s, _, _), .today(let s, _), .split(let s, _, _): s
        case .favorites: nil
        }
        if let sid, sid != other.currentSpaceID, other.windowSpaces.contains(where: { $0.id == sid }) { other.switchToSpace(sid, animated: false) }
        app.present(other)
        guard let first = tabs.first(where: { store.tab($0) != nil }) else { return }
        let wasShown = visibleTabIDs.contains(first)
        other.show(first, focus: true, takeOver: true)
        if wasShown, multiWindow.elsewhereTabID != nil { goOnAfterPageLeft(first) }
    }
}

/// SB-36: a selection's close waiting for its pages (WindowController.bulkClose): `finish` runs once, with every tab
/// whose page has closed by then.
final class BulkClose {
    private(set) var pending: Set<String>
    private var closed: Set<String>
    private var finish: ((Set<String>) -> Void)?

    init(pending: Set<String>, closed: Set<String>, finish: @escaping (Set<String>) -> Void) {
        self.pending = pending
        self.closed = closed
        self.finish = finish
    }

    func arrived(_ id: String) {
        guard pending.remove(id) != nil else { return }
        closed.insert(id)
        if pending.isEmpty { flush() }
    }

    func flush() {
        guard let f = finish else { return }
        finish = nil
        f(closed)
    }
}
