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

    /// "Back to Pinned URL" (SB-31). With ⌘, the current page stays open as a new Today tab. The tab comes to the front
    /// first; a page with changes it may not save asks before it's left (`resetTabs`).
    func resetToSaved(_ tabID: String, keepCurrent: Bool) {
        guard store.tab(tabID) != nil else { return }
        if tabID != shownTabID { show(tabID) }
        resetTabs([tabID], keepCurrent: keepCurrent)
    }

    /// P08, Arc's "Reset all tabs in this Space": every pinned tab of the Space away from its saved URL goes back to
    /// it (in folders and pinned splits too; Favorites belong to the profile). The tab on screen stays on screen.
    func resetAllTabsInSpace() {
        let ids = store.driftedPinnedTabs(inSpace: currentSpaceID).map(\.id)
        guard !ids.isEmpty else { return NSSound.beep() }
        resetTabs(ids, keepCurrent: false)
    }

    /// Resets pinned tabs and Favorites to their saved URLs. A loaded page that would ask "Leave site?" (it has
    /// changes it may not save; `wouldAskBeforeUnload`) is asked about first, in the page's own words for one tab and
    /// once for several; nothing changes unless the person leaves, and then nobody is asked again. Pages that wouldn't
    /// ask, and unloaded tabs, go back at once. `question` titles the one question for several tabs.
    func resetTabs(_ tabIDs: [String], keepCurrent: Bool, question: String = "Reset all tabs in this Space?") {
        let ids = tabIDs.filter { store.tab($0)?.itemID != nil && store.isDrifted($0) }
        guard !ids.isEmpty else { return }
        pagesThatWouldAsk(ids) { [weak self] asking in
            guard let self else { return }
            guard !asking.isEmpty else { return self.performReset(ids, neutralize: [], keepCurrent: keepCurrent) }
            let alert = NSAlert()
            if ids.count == 1 {
                alert.messageText = "Leave site?"
                alert.informativeText = "Changes you made may not be saved."
                alert.addButton(withTitle: "Leave")
            } else {
                alert.messageText = question
                alert.informativeText = asking.count == 1 ? "One of these pages has changes that may not be saved."
                    : "\(asking.count) of these pages have changes that may not be saved."
                alert.addButton(withTitle: "Reset All")
            }
            alert.addButton(withTitle: "Cancel")
            if ids.count > 1 { alert.addButton(withTitle: "Reset Others") }
            alert.buttons.first?.hasDestructiveAction = true
            #if AIRC_TESTING
            Self.lastResetAlert = alert
            #endif
            alert.beginSheetModal(for: self.window) { [weak self] r in
                guard let self else { return }
                switch r {
                case .alertFirstButtonReturn: self.performReset(ids, neutralize: Set(asking), keepCurrent: keepCurrent)
                case .alertThirdButtonReturn: self.performReset(ids.filter { !asking.contains($0) }, neutralize: [], keepCurrent: keepCurrent)
                default: break
                }
            }
        }
    }

    #if AIRC_TESTING
    /// The last reset question, for the P01 check (it answers with the alert's own buttons).
    static weak var lastResetAlert: NSAlert?
    #endif

    /// Which of `ids`' loaded pages would ask "Leave site?" now. A page that doesn't answer within a second (a busy
    /// renderer) counts as asking: better one question too many than lost work.
    private func pagesThatWouldAsk(_ ids: [String], _ done: @escaping ([String]) -> Void) {
        let live = ids.compactMap { id in engineTab(for: id).flatMap { $0.isClosed ? nil : (id, $0) } }
        guard !live.isEmpty else { return done([]) }
        var answers: [String: Bool] = [:], finished = false
        let loaded = Set(live.map(\.0))
        func finish() {
            guard !finished else { return }
            finished = true
            done(ids.filter { loaded.contains($0) && answers[$0] != false })
        }
        for (id, page) in live {
            page.evaluate(Self.wouldAskBeforeUnload) { v in
                answers[id] = (v as? Bool) == true
                if answers.count == live.count { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }
    }

    /// Loads each tab's saved URL, the store's change one ⌘Z step (`pagesFollowUndoneReset`). A page the person chose
    /// to leave (`neutralize`) has its "Leave site?" handlers switched off first, so the engine doesn't ask a second time.
    private func performReset(_ ids: [String], neutralize: Set<String>, keepCurrent: Bool) {
        let targets = ids.compactMap { id -> (String, URL)? in
            guard let tab = store.tab(id), let saved = store.item(tab.itemID)?.savedURL, let url = URL(string: saved) else { return nil }
            if keepCurrent {
                _ = try? store.openTab(url: engineTab(for: id)?.url?.absoluteString ?? tab.url, inSpace: currentSpaceID,
                                       background: true, activate: false, title: tab.title)
            }
            return (id, url)
        }
        _ = try? store.resetToSavedURLs(targets.map(\.0))
        for (id, url) in targets {
            guard let page = engineTab(for: id), !page.isClosed else { continue }
            let go = { [weak self, weak page] in
                guard let self, let page, !page.isClosed, self.engineTab(for: id) === page else { return }
                self.engineWindow.load(url, in: page)
            }
            if neutralize.contains(id) { page.evaluate(Self.skipBeforeUnload) { _ in go() } } else { go() }
        }
    }

    /// ⌘Z after a reset (WindowController.undo): the store has the tabs' addresses from before again; each page that
    /// is still at its saved URL goes back to its own, through its history when that's where it came from.
    func pagesFollowUndoneReset() {
        for w in app?.controllers ?? [self] {
            for (id, page) in w.pages where !page.isClosed {
                guard let t = store.tab(id), let saved = store.item(t.itemID)?.savedURL, let have = page.url?.absoluteString,
                      t.url != have, !URLRules.isDrifted(saved: saved, current: have), let u = URL(string: t.url) else { continue }
                if page.history.back.first?.url == t.url { page.goBack() } else { w.engineWindow.load(u, in: page) }
            }
        }
    }

    /// Switches off a page's "Leave site?" handlers once the person chose to leave it: its own `onbeforeunload` and,
    /// with a listener that runs before the page's, any it added.
    static let skipBeforeUnload = """
    (function(){try{window.onbeforeunload=null;
      window.addEventListener('beforeunload',function(e){e.stopImmediatePropagation()},true);}catch(x){}return true})()
    """

    func togglePin() {
        if let (page, ids) = sidebarSelection { return pinSelected(ids, spaceID: page.spaceID) }
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

    /// The page Copy URL, Markdown, Quote and Share take (C05): a Peek over the page, else the page on screen (in a
    /// split, the focused pane).
    var displayedLinkPage: EngineTab? {
        if let p = peek, !p.closing, !p.page.isClosed { return p.page }
        return shownTabID.flatMap { engineTab(for: $0) }
    }

    /// Copy URL, Markdown and Quote have something to copy: selected rows, or a displayed page with an address.
    var canCopyLink: Bool { sidebarSelection != nil || displayedLink != nil }

    /// The displayed page's address and title (the tab's stored ones while its page isn't there). Nil for a note.
    var displayedLink: (url: String, title: String)? {
        let page = displayedLinkPage
        if page !== peek?.page, store.isNoteTab(shownTabID) { return nil }
        guard let url = page?.url?.absoluteString ?? currentTab?.url else { return nil }
        let title = page?.title.isEmpty == false ? page!.title : (page === peek?.page ? "" : currentTab?.title ?? "")
        return (url, title)
    }

    /// ⇧⌘C (Arc's Copy URL): the selected rows' links while the sidebar has them, else the displayed page's, without
    /// its trackers.
    func copyURL() {
        if let (_, ids) = sidebarSelection { return copySelectedLinks(ids) }
        if peek == nil, noteHasNoLink() { return }
        guard let link = displayedLink else { return }
        let r = LinkCopyPolicy.cleaned(link.url)
        writeLinks(r.url, toast: LinkCopyPolicy.toast(count: 1, removedTrackers: r.removedTrackers, single: "Copied Current URL"))
    }

    func copyURLMarkdown() {
        if peek == nil, noteHasNoLink() { return }
        guard let link = displayedLink else { return }
        writeLinks(URLRules.markdownLink(title: link.title, url: LinkCopyPolicy.clean(link.url)), toast: "Copied URL as Markdown")
    }

    /// Scripted checks replace this with a pasteboard owned by the run.
    static var linkPasteboard: NSPasteboard = .general

    /// What a Quote was asked about: the page (Peek or tab) and its address, in this window, key or not. Any change
    /// before the selection arrives makes the answer come to nothing (LatestAnswerGate).
    struct QuoteContext: Equatable {
        let page: ObjectIdentifier?
        let url: String?
        let peek: Bool
        let key: Bool
    }

    func quoteContext() -> QuoteContext {
        let page = displayedLinkPage
        return QuoteContext(page: page.map(ObjectIdentifier.init), url: page?.url?.absoluteString,
                            peek: page != nil && page === peek?.page, key: window.isKeyWindow)
    }

    /// One for the app: there's one clipboard, and a later copy in any window wins.
    static let quoteGate = LatestAnswerGate<QuoteContext>()

    #if AIRC_TESTING
    /// The P01 check's late answer: the selection arrives this much later than the page gave it.
    static var quoteAnswerDelay: TimeInterval = 0
    #endif

    /// ⌃⇧⌘C (Arc's Copy URL as Quote): the page's selected text as a Markdown quote with a link back. The selection
    /// comes from the page a moment later; if another copy, another tab, a Peek or a navigation came first, it's
    /// dropped, never written over the newer clipboard.
    func copyURLQuote() {
        if peek == nil, noteHasNoLink() { return }
        guard let link = displayedLink else { return }
        let url = LinkCopyPolicy.clean(link.url), title = link.title
        let board = Self.linkPasteboard
        let ticket = Self.quoteGate.begin(quoteContext(), changeCount: board.changeCount)
        let copy: (String) -> Void = { [weak self] selection in
            guard let self, Self.quoteGate.finish(ticket, now: self.quoteContext(), changeCount: board.changeCount) else { return }
            board.clearContents()
            board.setString(URLRules.markdownQuote(title: title, url: url, selection: selection), forType: .string)
            self.showToast("Copied URL as Quote")
        }
        guard let page = displayedLinkPage else { return copy("") }
        page.evaluate("String(window.getSelection() || '')") { v in
            let selection = v as? String ?? ""
            #if AIRC_TESTING
            if Self.quoteAnswerDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.quoteAnswerDelay) { copy(selection) }
                return
            }
            #endif
            copy(selection)
        }
    }

    // MARK: Sign in to Google (SP-12)

    func showsSignInCard(spaceID: String) -> Bool {
        store.space(spaceID).map { showsSignInCard(space: $0) } ?? false
    }

    /// Also accepts the spare page drawn ahead for New Space.
    func showsSignInCard(space s: Space) -> Bool {
        guard let p = store.profile(s.profileID) else { return false }
        if p.googleSignIn == nil {
            if (UserDefaults.standard.stringArray(forKey: "AircDismissedSignIn") ?? []).contains(p.id) { return false }
            // Preserve the old invitation rule for existing/imported profiles. New profiles carry explicit state.
            if !store.todayTabs(ofSpace: s.id).isEmpty || !store.pinnedRoots(ofSpace: s.id).isEmpty { return false }
        }
        return p.signInState.showsCard
    }

    func dismissSignInCard(spaceID: String) {
        guard let pid = store.space(spaceID)?.profileID else { return }
        try? store.finishGoogleSignIn(pid, choice: store.profile(pid)?.signInState == .offered ? .declined : .dismissed)
    }

    func addGoogleFavorites(spaceID: String) {
        guard let pid = store.space(spaceID)?.profileID else { return }
        do { try store.finishGoogleSignIn(pid, choice: .added) }
        catch StoreError.favoritesFull { showToast("Make room for Gmail and Calendar in Favorites") }
        catch { showToast("Couldn’t save Favorites. Try again.") }
    }

    func signInToGoogle(spaceID: String) {
        guard let pid = store.space(spaceID)?.profileID else { return }
        var url = SignInWindowController.signInURL
        #if AIRC_TESTING
        if LaunchOptions.current.isAutomated {
            guard let mock = GoogleAccountProbe.testURL else { return }
            url = mock
        }
        #endif
        try? store.beginGoogleSignIn(pid)
        if spaceID != currentSpaceID { switchToSpace(spaceID, animated: true) }
        guard let tab = try? store.openTab(url: url.absoluteString, inSpace: spaceID) else { return }
        profileSignIn.restart(pid, tabID: tab.id)
        show(tab.id)
        profileSignIn.refresh()
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
            self?.renameSpace(spaceID, to: text)
        }
    }

    /// Rename (the header's field, Manage Spaces). An empty name leaves the Space unnamed, as Arc allows (P01c: the
    /// only Space, unnamed and without an icon, then hides its name row).
    func renameSpace(_ spaceID: String, to text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.space(spaceID)?.name != name else { return }
        try? store.updateSpace(spaceID) { $0.name = name }
    }

    func renameCurrentSpace() {
        guard let page = pageView(for: currentSpaceID) else { return }
        beginRenameSpace(currentSpaceID, in: page.header, titleFrame: NSRect(x: AircMetrics.SpaceHeader.nameX, y: 11,
                                                                             width: page.header.bounds.width - 80, height: 18))
    }

    // MARK: Menus

    func menu(for entry: SidebarEntry) -> NSMenu {
        if let item = entry.item, item.kind == .split { return itemSplitMenu(item, pane: nil) }   // SV-2
        if let m = noteMenu(for: entry) { return m }
        let m = NSMenu()
        switch entry {
        case .today(let t):
            // Arc 1.170's Today tab menu (docs/research/arc_behavior_spec.md §2.8): Copy Link · Share · Change Icon… · Rename… ·
            // Mute · Customize Page… · Add Split View · Duplicate · Move to · Archive Tab · Archive Tabs Below.
            m.add("Copy Link", ShortcutCenter.hint("edit.copyURL", "⇧⌘C")) { [weak self] in self?.copyLink(of: t.id) }
            addLinkItems(to: m, tabID: t.id, share: true)
            m.add("Change Icon…") { [weak self] in self?.changeTabIcon(t.id) }
            m.add("Rename…") { [weak self] in self?.renameTodayTab(t.id) }
            m.add(t.isMuted ? "Unmute" : "Mute") { [weak self] in self?.toggleMute(t.id) }
            addCustomizePage(to: m, tabID: t.id)
            m.add("Add Split View", ShortcutCenter.hint("tabs.newSplit", "⌃⇧+")) { [weak self] in self?.newSplitView(anchor: t.id) }
            m.add("Duplicate") { [weak self] in _ = try? self?.store.duplicateTab(t.id) }
            m.addItem(moveToMenu(tabID: t.id))
            // WIN-7 (Arc's "Move to New Window"): its page moves into a new window on this Space.
            m.add("Move to New Window") { [weak self] in self?.openInNewWindow(t.id) }
            m.addItem(.separator())
            m.add("Pin Tab", ShortcutCenter.hint("tabs.pin", "⌘D")) { [weak self] in
                guard let self else { return }
                try? self.store.togglePin(t.id, inSpace: self.currentSpaceID)
            }
            m.add("Add to Favorites") { [weak self] in
                guard let self else { return }
                self.performDrop(.tab(t.id), to: .favorites(profileID: t.profileID, index: 99))
            }.isEnabled = store.favorites(ofProfile: t.profileID).count < SpacesStore.maxFavorites
            m.addItem(.separator())
            m.add("Archive Tab", ShortcutCenter.hint("file.closeTab", "⌘W")) { [weak self] in self?.closeTab(t.id) }
            m.add("Archive Tabs Below") { [weak self] in self?.archiveBelow(t.id) }.isEnabled = !tabsBelow(t.id).isEmpty
        case .pinned(let item, _, let t), .favorite(let item, let t):
            // Arc's pinned tab and Favorite menus: the Today tab's actions that make sense for a saved row, then its
            // saved URL ("Edit Pinned Page ›", "Back to Pinned URL") and what keeps or removes the row.
            let isFav = item.isFavorite
            let drifted = t.map { store.isDrifted($0.id) } ?? false
            let live = t.flatMap { engineTab(for: $0.id) }
            m.add("Copy Link", ShortcutCenter.hint("edit.copyURL", "⇧⌘C")) { [weak self] in self?.copyLink(ofItem: item.id) }
            let md = m.add("Copy Link as Markdown") { [weak self] in self?.copyLinkMarkdown(ofItem: item.id) }
            md.isAlternate = true
            md.keyEquivalentModifierMask = .option
            if let share = SelectionShare([itemLink(item.id)].compactMap { $0 }) { m.addItem(share.menuItem()) }
            m.add("Change Icon…") { [weak self] in self?.changeItemIcon(item.id) }
            if !isFav { m.add("Rename…") { [weak self] in self?.renameItemFromMenu(item.id) } }
            let pinnedURL = NSMenuItem(title: "Edit Pinned Page", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.add("Replace Pinned URL with Current") { [weak self] in self?.replacePinnedURL(item.id) }.isEnabled = drifted
            sub.add("Edit…") { [weak self] in self?.editSavedURL(item.id) }
            pinnedURL.submenu = sub
            m.addItem(pinnedURL)
            if let t, drifted {
                m.add("Back to Pinned URL") { [weak self] in self?.resetToSaved(t.id, keepCurrent: false) }
            }
            if let t, live != nil {
                m.add(t.isMuted ? "Unmute" : "Mute") { [weak self] in self?.toggleMute(t.id) }
                addCustomizePage(to: m, tabID: t.id)
            }
            // Arc's "Open item in split view": this row beside the page on screen, as ⌥-click does (SplitActions.swift).
            if optionClickSplits(entry) {
                m.add("Open in Split View") { [weak self] in self?.optionClickSplit(entry) }.isEnabled =
                    shownTabID != nil && t?.id != shownTabID
            }
            // Arc's per-Favorite switch for the sites that count unread items in their title (Gmail, Slack, X…).
            if isFav, URLRules.showsUnreadBadge(item.savedURL ?? "") {
                let on = showsUnreadBadge(item)
                m.add("Show Unread Badge") { [weak self] in self?.setUnreadBadge(!on, item: item) }.state = on ? .on : .off
            }
            if !isFav {
                m.add("Duplicate") { [weak self] in _ = try? self?.store.duplicateItem(item.id) }
                m.addItem(moveItemMenu(item.id))
            } else if let move = moveFavoriteMenu(item.id) {
                m.addItem(move)   // P01c: Arc moves a Favorite to another profile's Favorites
            }
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
                let pid = store.profile(ofSpace: currentSpaceID).id
                m.add("Add to Favorites") { [weak self] in
                    self?.performDrop(.item(item.id), to: .favorites(profileID: pid, index: 99))
                }.isEnabled = store.favorites(ofProfile: pid).count < SpacesStore.maxFavorites
            }
            if let t { m.add(isFav ? "Close and Keep in Favorites" : "Close and Keep Pinned") { [weak self] in self?.closeTab(t.id) } }
            addCalendarItems(to: m, item: item)   // Live Calendar (Calendar/CalendarMenu.swift)
            m.add(isFav ? "Delete Favorite" : "Delete") { [weak self] in
                guard let self else { return }
                if let t { self.forgetPage(t.id, close: true) }
                try? self.store.deleteItem(item.id)
            }
        case .split:
            return menu(for: entry, pane: nil)
        case .folder(let item, _):
            // Arc's folder menu: Rename, Change Icon, its links (plain and as Markdown, nested folders included),
            // Duplicate, New Nested Folder, Delete.
            let links = store.folderLinks(item.id).compactMap(\.url)
            m.add("Rename…") { [weak self] in self?.renameItemFromMenu(item.id) }
            m.add("Change Icon…") { [weak self] in self?.changeFolderIcon(item.id) }
            m.addItem(.separator())
            m.add("Copy All Links") { [weak self] in self?.copyFolderLinks(item.id, markdown: false) }.isEnabled = !links.isEmpty
            m.add("Copy All Links as Markdown") { [weak self] in self?.copyFolderLinks(item.id, markdown: true) }.isEnabled = !links.isEmpty
            m.addItem(.separator())
            m.add("Duplicate") { [weak self] in _ = try? self?.store.duplicateItem(item.id) }
            m.add("New Nested Folder") { [weak self] in
                guard let self else { return }
                if self.store.item(item.id)?.isCollapsed == true { try? self.store.toggleFolder(item.id) }
                guard let f = try? self.store.createFolder(inSpace: self.currentSpaceID, parentID: item.id) else { return }
                DispatchQueue.main.async { self.renameItemFromMenu(f.id) }
            }
            // P01c: Arc's reset while the folder is focused, Move to ›, and Turn into Space (its newSpaceFromFolder).
            m.add("Reset all tabs in this Folder") { [weak self] in self?.resetFolder(item.id) }.isEnabled =
                !store.driftedPinnedTabs(inFolder: item.id).isEmpty
            m.addItem(moveItemMenu(item.id))
            m.add("Turn into Space") { [weak self] in self?.turnFolderIntoSpace(item.id) }
            m.addItem(.separator())
            m.add("Delete Folder") { [weak self] in self?.deleteItemWithPages(item.id) }
        }
        return m
    }

    /// Arc's "Customize Page…" (its Boost editor) for a tab's website, loaded or not: the tab comes to the front first.
    private func addCustomizePage(to m: NSMenu, tabID: String) {
        let page = engineTab(for: tabID).flatMap { $0.isClosed ? nil : $0 }
        let domain = BoostDomain.key(for: page?.url ?? store.tab(tabID).flatMap { URL(string: $0.url) })
        m.add("Customize Page…") { [weak self] in
            guard let self, let domain else { return }
            if self.shownTabID != tabID { self.show(tabID) }
            self.showBoostEditor(domain: domain, page: self.engineTab(for: tabID))
        }.isEnabled = boostsAvailable && domain != nil
    }

    /// The Today tabs "Archive Tabs Below" would archive.
    func tabsBelow(_ tabID: String) -> [String] {
        let today = store.todayRowTabs(ofSpace: currentSpaceID)
        guard let i = today.firstIndex(where: { $0.id == tabID }) else { return [] }
        let kept = visibleTabIDs
        return today[(i + 1)...].map(\.id).filter { !kept.contains($0) }
    }

    /// A pinned tab's or Favorite's link: its page's while it's loaded, else the saved URL.
    func itemLink(_ itemID: String) -> String? {
        if let t = store.liveTab(forItem: itemID), let u = linkURL(ofTab: t.id) { return u }
        return store.item(itemID)?.savedURL
    }

    func copyLink(ofItem itemID: String) {
        guard let u = itemLink(itemID) else { return NSSound.beep() }
        let r = LinkCopyPolicy.cleaned(u)
        writeLinks(r.url, toast: LinkCopyPolicy.toast(count: 1, removedTrackers: r.removedTrackers, single: "Copied Link"))
    }

    func copyLinkMarkdown(ofItem itemID: String) {
        guard let u = itemLink(itemID), let item = store.item(itemID) else { return NSSound.beep() }
        let title = store.liveTab(forItem: itemID).map(\.id).map(linkTitle(ofTab:)) ?? item.displayTitle
        writeLinks(URLRules.markdownLink(title: title.isEmpty ? item.displayTitle : title, url: LinkCopyPolicy.clean(u)),
                   toast: "Copied Link as Markdown")
    }

    /// "Replace Pinned URL with Current": the row's saved URL becomes the page it's on now.
    func replacePinnedURL(_ itemID: String) {
        guard let t = store.liveTab(forItem: itemID), let page = engineTab(for: t.id), let u = page.url else { return NSSound.beep() }
        try? store.replaceSavedURL(ofItem: itemID, with: u.absoluteString, title: page.title)
    }

    /// S11: "Copy All Links" and "Copy All Links as Markdown": the folder's rows in sidebar order, nested folders in
    /// place, without trackers.
    func copyFolderLinks(_ folderID: String, markdown: Bool) {
        let n = store.folderLinks(folderID).compactMap(\.url).count
        guard n > 0 else { return NSSound.beep() }
        if markdown {
            writeLinks(store.folderLinksMarkdown(folderID, clean: LinkCopyPolicy.clean), toast: n == 1 ? "Copied Link as Markdown" : "Copied \(n) Links as Markdown")
        } else {
            let plain = store.folderLinks(folderID).compactMap(\.url)
            let cleaned = plain.map(LinkCopyPolicy.cleaned)
            writeLinks(cleaned.map(\.url).joined(separator: "\n"),
                       toast: LinkCopyPolicy.toast(count: n, removedTrackers: cleaned.contains { $0.removedTrackers }, single: "Copied Link"))
        }
    }

    /// Arc's "Expand All Folders" / "Collapse All Folders" in the current Space.
    func setAllFolders(collapsed: Bool) {
        guard (try? store.setAllFolders(collapsed: collapsed, inSpace: currentSpaceID)) ?? 0 > 0 else { return NSSound.beep() }
    }

    /// A pinned row's "Move to ›": the other Spaces (it stays pinned there), then New Space….
    private func moveItemMenu(_ itemID: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in store.orderedSpaces where s.id != store.item(itemID)?.spaceID {
            sub.add(s.iconLabel + "  " + s.name) { [weak self] in self?.moveItem(itemID, toSpace: s.id) }
        }
        sub.addItem(.separator())
        sub.add("New Space…") { [weak self] in self?.openNewSpacePanel() }
        item.submenu = sub
        return item
    }

    /// A pinned tab moves to the top of another Space's pinned section. Into another profile's Space its page reloads
    /// with that profile's logins, so it asks first (as a Today tab's Move to does).
    func moveItem(_ itemID: String, toSpace spaceID: String) {
        guard let target = store.space(spaceID), let item = store.item(itemID) else { return }
        let tab = store.liveTab(forItem: itemID)
        let go = { [weak self] in
            guard let self else { return }
            let wasShown = tab.map { self.visibleTabIDs.contains($0.id) } ?? false
            let next = wasShown ? tab.flatMap { self.store.tabToSelect(afterClosing: $0.id, inSpace: self.currentSpaceID) } : nil
            do { self.reloadPagesInNewProfile(try self.store.move([.item(itemID)], toSpace: spaceID)) } catch { return NSSound.beep() }
            if wasShown { if let next { self.show(next.id) } else { self.showEmpty() } }
        }
        if tab != nil, store.profile(ofSpace: item.spaceID ?? currentSpaceID).id != target.profileID {
            confirmInterProfileMove(title: "Move this tab to “\(target.name)”?",
                                    message: "This page reloads with the other Profile’s logins and data, so it may look different.",
                                    confirm: "Move it", then: go)
        } else {
            go()
        }
    }

    // MARK: P01c: Favorites to other profiles, folder commands, the Space header, Shared Quotes

    /// A Favorite's "Move to ›" (Arc's "Submenu to chose which profile to move Favorite(s) to"): the other profiles that
    /// have a Space. Nil with only one.
    private func moveFavoriteMenu(_ itemID: String) -> NSMenuItem? {
        guard case .favorites(let pid)? = store.item(itemID)?.container else { return nil }
        let others = store.orderedProfiles.filter { $0.id != pid && !store.spaces(usingProfile: $0.id).isEmpty }
        guard !others.isEmpty else { return nil }
        let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in others {
            let row = sub.add(p.name) { [weak self] in self?.moveFavorite(itemID, toProfile: p.id) }
            row.image = ProfileAvatarImage.image(p, size: 16)
        }
        item.submenu = sub
        return item
    }

    /// The Favorite goes to the end of `profileID`'s Favorites, as one ⌘Z (a single row's store move isn't undoable on its
    /// own). Its page reloads with that profile's logins, so a loaded one asks first (as a pinned tab's move to another
    /// profile's Space does). A full grid says so.
    func moveFavorite(_ itemID: String, toProfile profileID: String) {
        guard let p = store.profile(profileID) else { return }
        let go = { [weak self] in
            guard let self else { return }
            do {
                let reload = try self.store.perform("Move Favorite", undoable: true) {
                    try self.store.move(.item(itemID), to: .favorites(profileID: profileID, index: self.store.favorites(ofProfile: profileID).count))
                }
                self.reloadPagesInNewProfile(reload)
            } catch StoreError.favoritesFull {
                self.showToast("Favorites are full (12)")
            } catch {
                NSSound.beep()
            }
        }
        if let t = store.liveTab(forItem: itemID), engineTab(for: t.id) != nil {
            confirmInterProfileMove(title: "Move this Favorite to “\(p.name)”?",
                                    message: "This page reloads with the other Profile’s logins and data, so it may look different.",
                                    confirm: "Move it", then: go)
        } else {
            go()
        }
    }

    /// "Reset all tabs in this Folder": the folder's pinned tabs away from their saved URLs go back, as Reset all tabs
    /// in this Space does (one question for pages with unsaved changes, one ⌘Z).
    func resetFolder(_ folderID: String) {
        let ids = store.driftedPinnedTabs(inFolder: folderID).map(\.id)
        guard !ids.isEmpty else { return NSSound.beep() }
        resetTabs(ids, keepCurrent: false, question: "Reset all tabs in this folder?")
    }

    /// "Turn into Space": the folder becomes a Space of its own (store.turnFolderIntoSpace), shown. One ⌘Z.
    func turnFolderIntoSpace(_ folderID: String) {
        guard let made = try? store.turnFolderIntoSpace(folderID) else { return NSSound.beep() }
        reloadPagesInNewProfile(made.reload)
        switchToSpace(made.space.id, animated: true)
    }

    /// Show / Hide Space Header, for every window.
    func setShowsSpaceHeader(_ shows: Bool) {
        app?.settings.values.showsSpaceHeaderOnSingleUnnamed = shows
        app?.controllers.forEach { $0.reloadAll(animated: false) }
    }

    /// Arc's Disable / Enable Shared Quotes: whether copying a page's selected text offers a link straight to it.
    func setSharedQuotes(_ on: Bool) {
        app?.settings.values.sharedQuotes = on
        if !on { quoteLinkOffer?.hide() }
        showToast(on ? "Shared Quotes are on" : "Shared Quotes are off")
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
        // P01c (Arc): the only Space, unnamed and without an icon, hides its name row; this brings it back, or hides it.
        if store.offersHeaderToggle(ofSpace: spaceID), let app {
            let shows = app.settings.values.showsSpaceHeaderOnSingleUnnamed
            m.add(shows ? "Hide Space Header" : "Show Space Header") { [weak self] in self?.setShowsSpaceHeader(!shows) }
        }
        let profileItem = NSMenuItem(title: "Set Profile", action: nil, keyEquivalent: "")
        profileItem.submenu = setProfileMenu(spaceID: spaceID, current: space.profileID)
        m.addItem(profileItem)
        m.addItem(.separator())
        m.add("New Folder…") { [weak self] in _ = try? self?.store.createFolder(inSpace: spaceID) }
        // WIN-7: this Space in a window of its own.
        m.add("Open in New Window") { [weak self] in self?.openSpaceInNewWindow(spaceID) }
        // P04 (Import/SidebarExport.swift): its tabs, folders and Favorites as Markdown or HTML another app can read.
        m.add("Export Space…") { [weak self] in self?.exportSpace(spaceID) }
        m.addItem(.separator())
        m.add("Manage Spaces…") { [weak self] in self?.showManageSpaces() }
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
        m.add("New Boost…", ShortcutCenter.hint("file.newBoost", "⌃⇧B")) { [weak self] in self?.newBoost() }
        m.add("New Space…") { [weak self] in self?.openNewSpacePanel() }
        m.add("New Folder…") { [weak self] in
            guard let self else { return }
            _ = try? self.store.createFolder(inSpace: self.currentSpaceID)
        }
        // Arc's order: New Space, New Folder, New Note, New Tab (Notes/NoteCenter.swift).
        addNewNoteItems(to: m)   // and New Airc Note when another app is chosen (Notes/NoteExport.swift)
        m.add("New Tab", "⌘T") { [weak self] in self?.openCommandBar(mode: .newTab) }
        // SV-1 (Arc's "New Right Split" / "New Bottom Split").
        m.add("New Split View", "⌃⇧+") { [weak self] in self?.newSplitView(axis: .horizontal) }
        m.add("New Bottom Split") { [weak self] in self?.newSplitView(axis: .vertical) }
        // P04 (Import/SidebarFileImport.swift): Arc's "Add Files" — files and folders into this Space.
        m.addItem(.separator())
        m.add("Add Files…") { [weak self] in self?.addFiles() }
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
        guard archiveQueue == nil, store.todayRowTabs(ofSpace: currentSpaceID).contains(where: { $0.id == tabID }) else { return }
        closeThenArchive(tabsBelow(tabID), reason: .manual, label: "Archive Tabs Below")
    }

    /// A row's Copy Link: its page's address (the one stored while it's unloaded), without trackers.
    func copyLink(of tabID: String) {
        guard let u = linkURL(ofTab: tabID) else { return }
        let r = LinkCopyPolicy.cleaned(u)
        writeLinks(r.url, toast: LinkCopyPolicy.toast(count: 1, removedTrackers: r.removedTrackers, single: "Copied Link"))
    }

    private func renameTodayTab(_ tabID: String) {
        // A Today tab gets a name by pinning it in Arc; we keep it simple: pin, then rename.
        try? store.togglePin(tabID, inSpace: currentSpaceID)
        if let itemID = store.tab(tabID)?.itemID {
            DispatchQueue.main.async { self.renameItemFromMenu(itemID) }
        }
    }

    func renameItemFromMenu(_ itemID: String) {
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
        alert.informativeText = deleteSpaceMessage(spaceID)
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

    /// What deleting a Space does to its tabs, in numbers (SB-23).
    func deleteSpaceMessage(_ spaceID: String) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        let today = store.todayTabs(ofSpace: spaceID).count
        let items = store.state.items.values.filter { $0.spaceID == spaceID && !$0.isFavorite }
        let pinned = items.filter { $0.kind != .folder }.count
        let folders = items.filter { $0.kind == .folder }.count
        var parts = ["Its open tabs close."]
        if today > 0 { parts.append("Its \(count(today, "Today tab goes", "Today tabs go")) to the Archive, where the Library can restore them.") }
        if pinned + folders > 0 {
            let what = [pinned > 0 ? count(pinned, "pinned tab", "pinned tabs") : nil, folders > 0 ? count(folders, "folder", "folders") : nil]
                .compactMap { $0 }.joined(separator: " and ")
            parts.append("Its \(what) \(pinned + folders == 1 ? "is" : "are") deleted with it.")
        }
        parts.append("Its profile stays. You can undo this with ⌘Z.")
        return parts.joined(separator: " ")
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

    func confirmInterProfileMove(title: String, message: String, confirm: String, then go: @escaping () -> Void) {
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

    /// Change Space Icon…, beside the Space's header; from Manage Spaces, beside its row (`anchor`), staying where it is.
    func changeSpaceIcon(_ spaceID: String, anchor: (view: NSView, rect: NSRect)? = nil) {
        let at: (view: NSView, rect: NSRect)
        if let anchor {
            at = anchor
        } else {
            guard let page = pageView(for: spaceID) else { return }
            if spaceID != currentSpaceID { switchToSpace(spaceID, animated: true) }
            at = (page.header, page.header.bounds)
        }
        let picker = EmojiPicker(onPick: { [weak self] e in
            try? self?.store.updateSpace(spaceID) { $0.icon = e.map(SpaceIcon.emoji) }
        })
        Popover.show(picker, size: NSSize(width: 273, height: 273), relativeTo: at.rect, of: at.view, edge: .maxX)
    }

    func changeFolderIcon(_ itemID: String) { changeItemIcon(itemID) }

    /// Arc's "Change Icon…" for a folder, a pinned tab or a Favorite: the emoji picker beside its row (its trash button
    /// gives the row its own icon back). The row draws the emoji in place of its favicon.
    func changeItemIcon(_ itemID: String) {
        guard let page = pageView(for: currentSpaceID) else { return }
        page.layoutSubtreeIfNeeded()
        let anchor: NSView = page.tileView(itemID) ?? page.rows[itemID] ?? page.header
        let picker = EmojiPicker(onPick: { [weak self] e in try? self?.store.setItemIcon(itemID, to: e) })
        Popover.show(picker, size: NSSize(width: 273, height: 273), relativeTo: anchor.bounds, of: anchor, edge: sidebarOnRight ? .minX : .maxX)
    }

    /// "Change Icon…" on a Today tab (its own emoji, kept when it's pinned; AircKit's setTabIcon), beside its row.
    func changeTabIcon(_ tabID: String) {
        if let iid = store.tab(tabID)?.itemID { return changeItemIcon(iid) }
        guard let page = pageView(for: currentSpaceID) else { return }
        page.layoutSubtreeIfNeeded()
        let anchor: NSView = page.rows[tabID] ?? page.header
        let picker = EmojiPicker(onPick: { [weak self] e in try? self?.store.setTabIcon(tabID, to: e) })
        Popover.show(picker, size: NSSize(width: 273, height: 273), relativeTo: anchor.bounds, of: anchor, edge: sidebarOnRight ? .minX : .maxX)
    }

    /// S03: whether a Favorite draws its unread dot (Arc's per-Favorite "Show Unread Badge", on until turned off).
    func showsUnreadBadge(_ item: Item) -> Bool { app?.settings.values.sidebarItems.showsUnreadBadge(item.id) ?? true }

    /// "Show Unread Badge" switched for `item`; every window's rows draw it again.
    func setUnreadBadge(_ on: Bool, item: Item) {
        guard let settings = app?.settings else { return }
        settings.values.sidebarItems.setUnreadBadge(on, for: item.id, existing: Set(store.state.items.keys))
        for w in app?.controllers ?? [self] { w.reloadAll(animated: false) }
    }

    /// Edit Theme Color… (TH-1): swatches, intensity, grain and appearance; recolours live. The Space is shown while it's
    /// edited; the picker sits beside its header, or beside `anchor` (Manage Spaces' row).
    func editTheme(_ spaceID: String, anchor: (view: NSView, rect: NSRect)? = nil) {
        guard let s = store.space(spaceID), let page = pageView(for: spaceID) else { return }
        if spaceID != currentSpaceID { switchToSpace(spaceID, animated: true) }
        let at = anchor ?? (page.header, page.header.bounds)
        showThemePicker(theme: s.theme, relativeTo: at.rect, of: at.view) { [weak self] theme in
            AppTelemetry.shared.record(.themeChanged, atMostEvery: 60)
            try? self?.store.updateSpace(spaceID) { $0.theme = theme }
        }
    }

    // MARK: The same actions in the Command Bar (C04)

    /// The menus' actions for the page on screen, its row, its folder and its Space, so typing finds them (Arc's
    /// TypeTravel names where Arc has one). Only the ones that would do something now are offered.
    func contextCommandActions() -> [CommandAction] {
        var a: [CommandAction] = []
        if !shareLinks.isEmpty {
            a.append(.init(title: "Share", symbol: "square.and.arrow.up", hint: ShortcutCenter.hint("file.share", ""),
                           keywords: ["share", "send", "airdrop", "messages", "mail", "link", "url"]) { [weak self] in self?.shareCurrent() })
        }
        let sid = currentSpaceID
        let folders = store.folders(inSpace: sid)
        if folders.contains(where: \.isCollapsed) {
            a.append(.init(title: "Expand All Folders", symbol: "folder", hint: ShortcutCenter.hint("tabs.expandFolders", ""),
                           keywords: ["folders", "open", "show", "reveal"]) { [weak self] in self?.setAllFolders(collapsed: false) })
        }
        if folders.contains(where: { !$0.isCollapsed }) {
            a.append(.init(title: "Collapse All Folders", symbol: "folder", hint: ShortcutCenter.hint("tabs.collapseFolders", ""),
                           keywords: ["folders", "close", "hide"]) { [weak self] in self?.setAllFolders(collapsed: true) })
        }
        if let s = store.space(sid), !store.pinnedRoots(ofSpace: sid).isEmpty {
            // Arc's Expand / Collapse Pinned Section (Sidebar/SidebarKeyboard.swift).
            let collapsed = s.pinnedCollapsed
            a.append(.init(title: collapsed ? "Expand Pinned Section" : "Collapse Pinned Section", symbol: "pin", hint: "",
                           keywords: ["pinned", "section", collapsed ? "show" : "hide", collapsed ? "expand" : "collapse"]) { [weak self] in
                self?.setPinnedSectionCollapsed(!collapsed)
            })
        }
        if shownTabID != nil {
            a.append(.init(title: "Reveal Tab in Sidebar", symbol: "sidebar.left", hint: ShortcutCenter.hint("tabs.revealInSidebar", ""),
                           keywords: ["reveal", "find", "sidebar", "where", "locate"]) { [weak self] in self?.revealTabInSidebar() })
        }
        if !store.driftedPinnedTabs(inSpace: sid).isEmpty {
            a.append(.init(title: "Reset all tabs in this Space", symbol: "arrow.uturn.backward", hint: ShortcutCenter.hint("tabs.resetSpace", ""),
                           keywords: ["reset", "pinned", "back", "saved", "url"]) { [weak self] in self?.resetAllTabsInSpace() })
        }
        // P04: files into the sidebar, and the Spaces out as a file.
        a.append(.init(title: "Add Files…", symbol: "doc.badge.plus", hint: "", keywords: ["files", "add", "import", "upload", "folder", "documents"]) { [weak self] in
            self?.addFiles()
        })
        a.append(.init(title: "Export Space…", symbol: "square.and.arrow.up.on.square", hint: "",
                       keywords: ["export", "save", "markdown", "html", "backup", "space"]) { [weak self] in
            guard let self else { return }
            self.exportSpace(self.currentSpaceID)
        })
        a.append(.init(title: "Export All Spaces…", symbol: "square.and.arrow.up.on.square", hint: ShortcutCenter.hint("file.exportSpaces", ""),
                       keywords: ["export", "save", "markdown", "html", "backup", "spaces", "all"]) { [weak self] in self?.exportSpace(nil) })
        // P01c: Arc's Disable / Enable Shared Quotes.
        if let app {
            let on = app.settings.values.sharedQuotes
            a.append(.init(title: on ? "Disable Shared Quotes" : "Enable Shared Quotes", symbol: "text.quote", hint: "",
                           keywords: ["quote", "shared quotes", "selection", "link to text", "highlight"]) { [weak self] in self?.setSharedQuotes(!on) })
        }
        // P06b: every Little Arc window at once (Window › Show/Close Little Arc Windows).
        if LittleArcGlobalActions.shared.hasLittleArcs {
            a.append(.init(title: "Show Little Airc Windows", symbol: "macwindow.on.rectangle", hint: "",
                           keywords: ["little arc", "mini", "windows", "show", "front"]) { LittleArcGlobalActions.shared.showAll() })
            a.append(.init(title: "Close Little Airc Windows", symbol: "xmark.rectangle", hint: "",
                           keywords: ["little arc", "mini", "windows", "close", "archive"]) { LittleArcGlobalActions.shared.closeAll() })
        }
        guard let t = currentTab, !store.isNoteTab(t.id) else { return a }
        let live = engineTab(for: t.id)
        a.append(.init(title: "Change Icon…", symbol: "face.smiling", hint: "", keywords: ["icon", "emoji", "customize", "tab"]) { [weak self] in
            self?.changeTabIcon(t.id)
        })
        if live != nil {
            a.append(.init(title: t.isMuted ? "Unmute Tab" : "Mute Tab", symbol: t.isMuted ? "speaker.wave.2" : "speaker.slash", hint: "",
                           keywords: ["mute", "unmute", "sound", "audio", "silence"]) { [weak self] in self?.toggleMute(t.id) })
        }
        if boostsAvailable, let page = live, BoostDomain.key(for: page.url) != nil {
            a.append(.init(title: "Customize Page…", symbol: "paintbrush.pointed", hint: "",
                           keywords: ["customize", "boost", "style", "css", "page"]) { [weak self] in self?.showBoostEditor() })
        }
        if t.isToday {
            if !tabsBelow(t.id).isEmpty {
                a.append(.init(title: "Archive Tabs Below", symbol: "archivebox", hint: "", keywords: ["archive", "close", "below", "clean"]) { [weak self] in
                    self?.archiveBelow(t.id)
                })
            }
            return a
        }
        guard let item = store.item(t.itemID) else { return a }
        if store.isDrifted(t.id) {
            // Arc: "Replace Pinned Tab with the Current Site".
            a.append(.init(title: "Replace Pinned URL with Current", symbol: "pin", hint: "",
                           keywords: ["replace", "pin", "pinned", "favorite", "saved", "url", "update"]) { [weak self] in self?.replacePinnedURL(item.id) })
        }
        a.append(.init(title: item.isFavorite ? "Edit Favorite…" : "Edit Pinned Page…", symbol: "pencil", hint: "",
                       keywords: ["edit", "pinned", "favorite", "url", "rename", "name"]) { [weak self] in self?.editSavedURL(item.id) })
        if !item.isFavorite {
            for s in store.orderedSpaces where s.id != item.spaceID {
                // Arc: "Move to Pinned in <Space>".
                a.append(.init(title: "Move to Pinned in \(s.name)", symbol: "arrow.right.square", hint: "", keywords: ["move", "space", "pinned"]) { [weak self] in
                    self?.moveItem(item.id, toSpace: s.id)
                })
            }
        }
        if let folder = store.item(item.parentID), folder.kind == .folder {
            let name = TextLimits.clip(folder.displayTitle)
            a.append(.init(title: "Copy All Links in “\(name)”", symbol: "link", hint: "", keywords: ["copy", "links", "folder", "urls"]) { [weak self] in
                self?.copyFolderLinks(folder.id, markdown: false)
            })
            a.append(.init(title: "Copy All Links in “\(name)” as Markdown", symbol: "text.badge.plus", hint: "",
                           keywords: ["copy", "links", "folder", "markdown", "urls"]) { [weak self] in self?.copyFolderLinks(folder.id, markdown: true) })
        }
        return a
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

final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
    var handler: (() -> Void)?
    /// The enabled state the menu's builder gave it. Menus enable every item whose target answers its action when they
    /// validate (before they show), so the item answers with this instead.
    private var wantsEnabled = true
    override var isEnabled: Bool {
        get { super.isEnabled }
        set { wantsEnabled = newValue; super.isEnabled = newValue }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { wantsEnabled }
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
