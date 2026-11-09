// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

// P03 (K04, Q01): the sidebar without a mouse. Arc's Reveal Current Tab (⌃Space, its menu action "focusSidebar") puts
// the keyboard on the current tab's row, opening the folders and the folded pinned section it sits in. From there the
// arrows walk every section (AircKit's SidebarNavigator: the Favorites grid by column, the Space header, folders,
// Today), → and ← open and close folders in place without loading anything, Tab and ⇧Tab jump by section, typing a
// name's first letters selects it, Space shows the row's page and stays in the sidebar, Return shows it and gives the
// keyboard to the page, and Esc gives the keyboard back to the page. The focused row is the window's first responder,
// so VoiceOver follows it (SidebarRowView's accessibility: an outline of rows with names, selection and expanded state).

extension WindowController {
    /// Arc's "Reveal Current Tab" (⌃Space): the keyboard goes to the current tab's row, with everything above it opened.
    func revealCurrentTab() {
        guard let page = pageView(for: currentSpaceID) else { return }
        openRevealPlan(forTab: shownTabID, page: page)
        showSidebarForKeyboard()
        let target = page.rowID(showing: shownTabID) ?? page.navItems.first?.id
        page.focusKeyboard(on: target)
    }

    /// Arc's "Reveal Tab in Sidebar": the current tab's row shows (folders opened, scrolled to, the sidebar out if it was
    /// hidden), and the keyboard stays where it is.
    func revealTabInSidebar() {
        guard let page = pageView(for: currentSpaceID) else { return }
        openRevealPlan(forTab: shownTabID, page: page)
        if sidebarHidden, revealController?.isRevealed != true { revealController?.reveal() }
        if let id = page.rowID(showing: shownTabID) { page.scrollRowVisible(id) }
    }

    /// Arc's "Expand Pinned Section" / "Collapse Pinned Section" for the current Space.
    func setPinnedSectionCollapsed(_ collapsed: Bool) {
        guard let s = store.space(currentSpaceID), s.pinnedCollapsed != collapsed else { return }
        togglePinnedCollapsed(currentSpaceID)
    }

    /// Opens what hides `tabID`'s row and draws the page at once, so the row can take the keyboard now.
    private func openRevealPlan(forTab tabID: String?, page: SpacePageView) {
        guard let plan = store.revealPlan(forTab: tabID, inSpace: currentSpaceID), !plan.isEmpty else { return }
        try? store.perform(nil) {
            if plan.expandPinnedSection { try store.updateSpace(currentSpaceID) { $0.pinnedCollapsed = false } }
            for f in plan.foldersToOpen { try store.toggleFolder(f) }
        }
        page.reload(animated: true)
    }

    /// The keyboard is in the sidebar: a hidden one slides out (and comes back if the pointer sent it away meanwhile).
    func showSidebarForKeyboard() {
        if sidebarHidden, sidebarFraction <= 0.001, revealController?.isRevealed != true { revealController?.reveal() }
    }

    /// The page shown, or the window, takes the keyboard back (Esc, Return). The engine focuses its page (Chromium's
    /// page view may take it a moment later); until it has, the page's own view that takes the keyboard gets it.
    func focusShownPage() {
        // A note on screen (Notes/NoteCenter.swift) has no engine page: its editor takes the keyboard.
        if let note = shownNote?.view, note.window === window {
            window.makeFirstResponder(Self.firstKeyView(in: note) ?? note)
            return
        }
        guard let id = shownTabID, let tab = engineTab(for: id), tab.view.window === window else {
            window.makeFirstResponder(nil)
            return
        }
        tab.focus()
        if let r = window.firstResponder as? NSView, r === tab.view || r.isDescendant(of: tab.view) { return }
        window.makeFirstResponder(Self.firstKeyView(in: tab.view) ?? tab.view)
    }

    /// The first view inside `view` that takes the keyboard (Chromium's page view inside its container).
    private static func firstKeyView(in view: NSView) -> NSView? {
        if view.acceptsFirstResponder { return view }
        for v in view.subviews where !v.isHidden { if let hit = firstKeyView(in: v) { return hit } }
        return nil
    }
}

// MARK: K06, Arc's tab switcher

/// ⌃Tab and ⌃⇧Tab walk this Space's recent tabs while ⌃ is held (AircKit's TabSwitcherWalk), one walk per window.
/// OptionReveal's modifier monitor reports ⌃ (`modifiersChanged`); letting it go ends every walk, and only the tab it
/// stopped on counts as used.
enum TabSwitcher {
    fileprivate struct Walk {
        var walk: TabSwitcherWalk
        weak var controller: WindowController?
    }
    nonisolated(unsafe) fileprivate static var walks: [ObjectIdentifier: Walk] = [:]
    nonisolated(unsafe) private(set) static var controlDown = false

    static func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        controlDown = flags.contains(.control)
        if !controlDown { endWalks() }
    }

    /// ⌃ is down now: as the modifier monitor saw it, or the hardware's (the first press after launch).
    static var controlHeld: Bool { controlDown || NSEvent.modifierFlags.contains(.control) }

    fileprivate static func endWalks() {
        for w in walks.values {
            guard let c = w.controller else { continue }
            try? c.store.restoreLastUse(w.walk.lastUse, except: c.shownTabID)
        }
        walks = [:]
    }
}

extension WindowController {
    /// Arc's "Tab Switcher (forward)" (⌃Tab, offset 1) and "(backward)" (⌃⇧Tab, -1): the tab used before this one at
    /// once; with ⌃ still held, each press goes one further through the five most recent tabs of this Space.
    func cycleRecentTab(_ offset: Int) {
        let key = ObjectIdentifier(self)
        var walk = TabSwitcher.controlHeld ? TabSwitcher.walks[key]?.walk : nil
        if walk == nil || walk?.order.contains(shownTabID ?? "") == false {
            let recent = store.recentTabs(inSpace: currentSpaceID)
            walk = TabSwitcherWalk(recent: recent, current: shownTabID, lastUse: store.lastUse(of: recent))
        }
        guard var w = walk else { return NSSound.beep() }
        let id = w.step(offset)
        TabSwitcher.walks[key] = TabSwitcher.controlHeld ? TabSwitcher.Walk(walk: w, controller: self) : nil
        show(id)
    }
}

// MARK: P03b, Arc's Cycle Tab

/// ⌃⌘→ and ⌃⌘← go through every tab of this Space in the order they were last used (AircKit's TabCycle), one cycle per
/// window. It goes on while the tab on screen is the one it showed; anything else that shows a tab starts the next one.
enum TabCycler {
    nonisolated(unsafe) fileprivate static var cycles: [ObjectIdentifier: TabCycle] = [:]

    #if AIRC_TESTING
    /// ParityP03bCheck: the cycle a window is on.
    static func cycle(of c: WindowController) -> TabCycle? { cycles[ObjectIdentifier(c)] }
    #endif
}

extension WindowController {
    /// Arc's "Cycle Tab Forward" (⌃⌘→, offset 1: the tab used before this one, then the one before that …) and
    /// "Cycle Tab Backward" (⌃⌘←, -1). Only the tab it stops on counts as used.
    func cycleTab(_ offset: Int) {
        let key = ObjectIdentifier(self)
        let recent = store.recentTabs(inSpace: currentSpaceID)
        var cycle = TabCycler.cycles[key]
        if cycle?.continues(inSpace: currentSpaceID, shown: shownTabID) != true {
            cycle = TabCycle(spaceID: currentSpaceID, recent: recent, current: shownTabID, lastUse: store.lastUse(of: recent))
        }
        guard var c = cycle, let id = c.step(offset, open: Set(recent)) else {
            TabCycler.cycles[key] = nil
            return NSSound.beep()
        }
        TabCycler.cycles[key] = c
        show(id)
        try? store.restoreLastUse(c.lastUse, except: id)
    }
}

extension SpacePageView {
    var navigator: SidebarNavigator { SidebarNavigator(items: navItems, favoriteColumns: favoriteColumns) }

    func navItem(_ id: String?) -> SidebarNavItem? { id.flatMap { navIndex[$0] }.map { navItems[$0] } }

    /// The view of a keyboard row: a Favorite's tile, the header, a list row.
    func navRow(_ id: String?) -> SidebarRowView? {
        guard let id else { return nil }
        if id == SpacePageView.headerNavID { return header }
        if let t = tileView(id) { return t }
        return rows[id]
    }

    /// Every keyboard row's view, top to bottom (the accessibility outline's rows).
    var navRowViews: [SidebarRowView] { navItems.compactMap { navRow($0.id) } }

    /// The row that shows `tabID`: its Favorite, its split, its pinned or Today row.
    func rowID(showing tabID: String?) -> String? {
        guard let tabID, let c = controller else { return nil }
        for i in navItems where i.kind == .favorite {
            guard let item = c.store.item(i.id) else { continue }
            let live = item.kind == .split ? c.store.liveTab(forSplitItem: item.id) : c.store.liveTab(forItem: item.id)
            if live?.id == tabID { return i.id }
            // A Favorite split shows on its tile, whichever pane is focused.
            if item.kind == .split, c.store.splitItem(ofPane: c.store.tab(tabID)?.itemID)?.id == item.id { return i.id }
        }
        return orderedEntries.first { $0.entry.shows(tabID) }?.id
    }

    /// The keyboard goes to the row `id` (scrolled into view; built first if a long list left it unbuilt).
    @discardableResult
    func focusKeyboard(on id: String?) -> Bool {
        guard let id, let window else { return false }
        if navRow(id) == nil, let f = rowFrame(id) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, f.midY - scrollView.contentSize.height / 2)))
            reload(animated: false)
        }
        guard let row = navRow(id) else { return false }
        isMovingKeyboardFocus = true
        defer { isMovingKeyboardFocus = false }
        guard window.firstResponder === row || window.makeFirstResponder(row) else { return false }
        keyboardFocusID = id
        keyboardActive = true
        scrollRowVisible(id)
        NSAccessibility.post(element: row, notification: .focusedUIElementChanged)
        return true
    }

    func scrollRowVisible(_ id: String) {
        guard let row = navRow(id), row.superview === list else { return }
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -AircMetrics.Row.pitch / 2))
    }

    /// The keyboard leaves the sidebar: to the page (`toPage`), or wherever it went.
    func endKeyboardFocus(toPage: Bool) {
        let wasRow = navRow(keyboardFocusID)
        keyboardActive = false
        keyboardFocusID = nil
        typeahead = ("", 0)
        if toPage, let c = controller {
            c.focusShownPage()
            if let wasRow, window?.firstResponder === wasRow { window?.makeFirstResponder(nil) }
        }
    }

    func rowDidTakeKeyboardFocus(_ row: SidebarRowView) {
        if let id = row.navID { keyboardFocusID = id; keyboardActive = true }
    }

    /// A row gave up the keyboard. A render that replaced the row hands it to the new one (`keepKeyboardFocusAfterRender`);
    /// anything else (a click on the page, the Command Bar) ends the sidebar's turn.
    func rowDidLoseKeyboardFocus(_ row: SidebarRowView) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keyboardActive, let window = self.window else { return }
            if let r = window.firstResponder as? SidebarRowView, r.page === self, r.navID != nil { return }
            if self.isRendering { return }
            self.keyboardActive = false
            self.keyboardFocusID = nil
        }
    }

    /// After a render: the focused row may be a new view, or gone (closed, folded away): the keyboard stays on the row,
    /// or moves to the one now in its place.
    func keepKeyboardFocusAfterRender(previousItems: [SidebarNavItem]) {
        guard keyboardActive, let window, let id = keyboardFocusID else { return }
        let responder = window.firstResponder
        let free = responder == nil || responder === window || ((responder as? SidebarRowView).map { $0.page == nil || $0.page === self } ?? false)
        guard free else { return }
        if let row = navRow(id) {
            if responder !== row { focusKeyboard(on: id) }
            return
        }
        guard !navItems.isEmpty else { return endKeyboardFocus(toPage: true) }
        // The row went: the one after it (now in its place), else the one before.
        let old = previousItems.firstIndex { $0.id == id } ?? 0
        let after = previousItems[(old + 1)...].first { p in navItems.contains { $0.id == p.id } }
        let before = previousItems[..<old].last { p in navItems.contains { $0.id == p.id } }
        focusKeyboard(on: after?.id ?? before?.id ?? navItems[min(old, navItems.count - 1)].id)
    }

    /// The focused row's keys. False: not the sidebar's (shortcuts with ⌘ ⌥ ⌃ go on to the menus).
    func sidebarKeyDown(_ e: NSEvent, row: SidebarRowView) -> Bool {
        guard let c = controller, let id = row.navID else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.subtracting(.shift).isEmpty else { return false }
        let shift = mods.contains(.shift)
        if e.keyCode != 53 { c.showSidebarForKeyboard() }
        var key: SidebarNavKey?
        switch e.keyCode {
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        case 115: key = .home
        case 119: key = .end
        case 116: key = .pageUp
        case 121: key = .pageDown
        case 48: key = shift ? .previousSection : .nextSection
        case 36, 76:
            performPrimaryAction(row, keepKeyboard: false)
            return true
        case 49 where typeahead.text.isEmpty || CACurrentMediaTime() - typeahead.at > Self.typeaheadPause:
            performPrimaryAction(row, keepKeyboard: true)
            return true
        case 53:
            // P03b's Esc order (Command Bar, Peek, find, full screen, the sidebar's keyboard): the find bar over the page
            // closes first and the sidebar keeps the keyboard; the next Esc gives it back to the page.
            if c.findBar != nil {
                c.closeFind(refocusPage: false)
                if window?.firstResponder !== row { focusKeyboard(on: id) }
                return true
            }
            endKeyboardFocus(toPage: true)
            return true
        default: break
        }
        if let key {
            // ⇧↑ ⇧↓ pick rows (SB-36's multi-selection, as ⇧-clicks do); the selection then has the keyboard.
            if shift, key == .up || key == .down {
                guard isSelectable(id), case .focus(let next) = navigator.move(key, from: id), isSelectable(next) else {
                    NSSound.beep()
                    return true
                }
                selectRange(from: id, to: next)
                return true
            }
            if shift, key != .previousSection { return false }
            apply(navigator.move(key, from: id))
            return true
        }
        // Type-to-select: the letters the layout types (an ä on an Austrian keyboard is one key).
        guard let typed = e.characters, !typed.isEmpty,
              typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return false }
        let now = CACurrentMediaTime()
        if now - typeahead.at > Self.typeaheadPause { typeahead.text = "" }
        typeahead = (typeahead.text + typed, now)
        if let hit = navigator.typeahead(typeahead.text, from: id) { focusKeyboard(on: hit) } else { NSSound.beep() }
        return true
    }

    /// The selection's keys while it has the keyboard (Esc, Delete, ⌘W … are the key monitor's, SelectionActions):
    /// ⇧↑ ⇧↓ move its end; ↑ ↓ leave it for the row next to its end, with the keyboard on that row.
    func selectionKeyDown(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty || mods == .shift, e.keyCode == 125 || e.keyCode == 126,
              let end = keyboardSelectionEnd.flatMap({ selection.contains($0) ? $0 : nil }) ?? selection.last else { return false }
        let key: SidebarNavKey = e.keyCode == 125 ? .down : .up
        guard case .focus(let next) = navigator.move(key, from: end) else { NSSound.beep(); return true }
        if mods == .shift {
            if isSelectable(next), let anchor = keyboardSelectionAnchor { selectRange(from: anchor, to: next) } else { NSSound.beep() }
        } else {
            clearSelection()
            focusKeyboard(on: next)
        }
        return true
    }

    /// Finder's: a pause this long starts a new word.
    static let typeaheadPause: CFTimeInterval = 1.0

    private func apply(_ move: SidebarNavMove) {
        guard let c = controller else { return }
        switch move {
        case .focus(let id): focusKeyboard(on: id)
        case .expand(let id), .collapse(let id):
            let collapse: Bool
            if case .collapse = move { collapse = true } else { collapse = false }
            if id == Self.headerNavID {
                if (c.store.space(spaceID)?.pinnedCollapsed ?? false) != collapse { c.togglePinnedCollapsed(spaceID) }
            } else if let f = c.store.item(id), f.isCollapsed != collapse {
                c.toggleFolder(id)
            }
            // Draw it now so the next key sees the rows as they are.
            reload(animated: true)
            if let row = navRow(id) { NSAccessibility.post(element: row, notification: collapse ? .rowCollapsed : .rowExpanded) }
        case .none: NSSound.beep()
        }
    }

    /// A row's own action, as a plain click has it (Return, Space, VoiceOver's press): a tab shows; a folder or the
    /// header opens or closes; New Tab opens the Command Bar. `keepKeyboard`: the sidebar keeps the keyboard after a tab
    /// shows (Space); otherwise the page gets it (Return).
    @discardableResult
    func performPrimaryAction(_ row: SidebarRowView, keepKeyboard: Bool) -> Bool {
        guard let c = controller, let id = row.navID, let item = navItem(id) else { return false }
        switch item.kind {
        case .header, .folder:
            apply(item.isExpanded == true ? .collapse(id) : .expand(id))
            return true
        case .newTab:
            endKeyboardFocus(toPage: false)
            c.openCommandBar(mode: .newTab)
            return true
        case .favorite, .row:
            guard let entry = entry(for: id) else { return false }
            c.activate(entry: entry)
            if keepKeyboard {
                // Showing a page gives it the keyboard (the engine focuses it, sometimes a moment later): take it back.
                focusKeyboard(on: id)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.keyboardActive, self.keyboardFocusID == id else { return }
                    self.focusKeyboard(on: id)
                }
            } else {
                endKeyboardFocus(toPage: true)
            }
            return true
        }
    }

    /// The sidebar entry a keyboard row stands for.
    func entry(for id: String) -> SidebarEntry? {
        guard let c = controller else { return nil }
        if let i = navItem(id), i.kind == .favorite, let item = c.store.item(id) {
            return .favorite(item, item.kind == .split ? c.store.liveTab(forSplitItem: item.id) : c.store.liveTab(forItem: item.id))
        }
        return orderedEntries.first { $0.id == id }?.entry
    }

    /// The navigation model of what the last render drew, top to bottom.
    func buildNavItems(favorites favs: [Item], columns: Int, space: Space, entries: [(id: String, entry: SidebarEntry)],
                       hasNewTab: Bool) -> [SidebarNavItem] {
        var out: [SidebarNavItem] = favs.map { f in
            SidebarNavItem(id: f.id, kind: .favorite, section: .favorites, title: favoriteTitle(f))
        }
        // A hidden name row (P01c: the only Space, unnamed) isn't a stop.
        if !header.isHidden {
            out.append(SidebarNavItem(id: Self.headerNavID, kind: .header, section: .pinned, title: space.name,
                                      isExpanded: !space.pinnedCollapsed))
        }
        var addedNewTab = false
        for (id, e) in entries {
            switch e {
            case .folder(let item, let depth):
                out.append(.init(id: id, kind: .folder, section: .pinned, title: item.displayTitle, depth: depth + 1,
                                 parentID: item.parentID ?? Self.headerNavID, isExpanded: !item.isCollapsed))
            case .pinned(let item, let depth, _):
                out.append(.init(id: id, kind: .row, section: .pinned, title: rowTitle(e), depth: depth + 1,
                                 parentID: item.parentID ?? Self.headerNavID))
            case .today, .split:
                if hasNewTab, !addedNewTab {
                    out.append(.init(id: Self.newTabNavID, kind: .newTab, section: .today, title: "New Tab"))
                    addedNewTab = true
                }
                out.append(.init(id: id, kind: .row, section: .today, title: rowTitle(e)))
            case .favorite: break
            }
        }
        if hasNewTab, !addedNewTab { out.append(.init(id: Self.newTabNavID, kind: .newTab, section: .today, title: "New Tab")) }
        return out
    }

    private func favoriteTitle(_ f: Item) -> String {
        guard f.kind == .split, let c = controller, let tab = c.store.liveTab(forSplitItem: f.id),
              let x = c.store.split(containing: tab.id) else { return f.displayTitle }
        return f.title?.isEmpty == false ? f.displayTitle : c.store.members(of: x).map(\.displayTitle).joined(separator: " and ")
    }

    private func rowTitle(_ e: SidebarEntry) -> String {
        guard let c = controller else { return "" }
        switch e {
        case .split(_, let tabs):
            return tabs.map { pageTitle($0) }.joined(separator: " and ")
        case .pinned(let item, _, let tab):
            if item.kind == .split, let tab, let x = c.store.split(containing: tab.id) {
                return item.title?.isEmpty == false ? item.displayTitle : c.store.members(of: x).map(\.displayTitle).joined(separator: " and ")
            }
            return item.displayTitle
        case .today(let t):
            return pageTitle(t)
        case .favorite(let i, _), .folder(let i, _): return i.displayTitle
        }
    }

    /// A tab's title as its row shows it: the page's own once it has one.
    private func pageTitle(_ t: LiveTab) -> String {
        if let title = controller?.engineTab(for: t.id)?.title, !title.isEmpty { return title }
        return t.displayTitle
    }

    static let headerNavID = "space-header"
    static let newTabNavID = "newtab"

    // MARK: VoiceOver

    /// What VoiceOver says the row is (Arc gives its tab cells a role description too).
    func accessibilityRoleDescription(of id: String?) -> String? {
        guard let i = navItem(id) else { return nil }
        switch i.kind {
        case .favorite: return controller?.store.item(i.id)?.kind == .split ? "Favorite split view" : "Favorite"
        case .header: return "Space"
        case .folder: return "folder"
        case .newTab: return "button"
        case .row:
            guard let e = entry(for: i.id) else { return "tab" }
            switch e {
            case .split: return "split view"
            case .pinned(let item, _, _): return item.kind == .split ? "pinned split view" : "pinned tab"
            default: return NoteURL.isNote(e.liveTab?.url) ? "note" : "tab"
            }
        }
    }

    /// Spoken after the name: the header's pinned section; an unloaded or audible tab.
    func accessibilityValue(of id: String?) -> String? {
        guard let i = navItem(id), let c = controller else { return nil }
        switch i.kind {
        case .header: return SpaceHeaderPolicy.accessibilityValue(c.store.headerState(ofSpace: spaceID, shownTabID: c.displayedTabID(forSpace: spaceID)))
        case .folder: return i.isExpanded == true ? "expanded" : "collapsed"
        case .row, .favorite:
            guard let e = entry(for: i.id) else { return nil }
            var parts: [String] = []
            if let t = e.liveTab, let page = c.engineTab(for: t.id) {
                if page.isAudible { parts.append(t.isMuted ? "muted" : "playing sound") }
            } else if e.item != nil {
                parts.append("not loaded")
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .newTab: return nil
        }
    }

    /// VoiceOver's level: Favorites, the header and Today at 0; pinned rows one deeper than their folders.
    func accessibilityLevel(of id: String?) -> Int { navItem(id)?.depth ?? 0 }
}

/// The sidebar page as VoiceOver sees it: one outline of rows (Favorites, the Space header, pinned rows and folders,
/// New Tab, Today), whatever views they sit in, with the shown tab selected.
final class SidebarOutlineElement: NSAccessibilityElement {
    weak var page: SpacePageView?

    init(page: SpacePageView) {
        self.page = page
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .outline }
    override func accessibilityLabel() -> String? {
        guard let page, let space = page.controller?.store.space(page.spaceID) else { return "Sidebar" }
        return "Sidebar, \(space.name)"
    }
    override func accessibilityParent() -> Any? { page }
    override func accessibilityChildren() -> [Any]? { page?.navRowViews }
    override func accessibilityRows() -> [Any]? { page?.navRowViews }
    override func accessibilityVisibleRows() -> [Any]? {
        guard let page else { return nil }
        let visible = page.scrollView.documentVisibleRect
        return page.navRowViews.filter { $0.superview !== page.list || $0.frame.intersects(visible) }
    }
    override func accessibilitySelectedRows() -> [Any]? {
        page?.navRowViews.filter { $0.isAccessibilitySelected() }
    }
    override func accessibilityFrame() -> NSRect {
        guard let page, let window = page.window else { return .zero }
        return window.convertToScreen(page.convert(page.bounds, to: nil))
    }
    override func isAccessibilityFocused() -> Bool { false }
}

/// A folder's (or the header's) disclosure triangle for VoiceOver: its value says whether the row is open; pressing it
/// opens or closes the row in place.
final class SidebarDisclosureElement: NSAccessibilityElement {
    weak var row: SidebarRowView?

    init(row: SidebarRowView) {
        self.row = row
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func accessibilityParent() -> Any? { row }
    override func accessibilityValue() -> Any? { (row?.isAccessibilityExpanded() ?? false) ? 1 : 0 }
    override func accessibilityLabel() -> String? { (row?.isAccessibilityExpanded() ?? false) ? "Collapse" : "Expand" }
    override func accessibilityFrame() -> NSRect {
        guard let row, let window = row.window else { return .zero }
        let r = NSRect(x: AircMetrics.Row.faviconX - 4, y: (row.bounds.height - 22) / 2, width: 24, height: 22)
        return window.convertToScreen(row.convert(r, to: nil))
    }
    override func accessibilityPerformPress() -> Bool {
        guard let row, let page = row.page else { return false }
        return page.performPrimaryAction(row, keepKeyboard: true)
    }
}
