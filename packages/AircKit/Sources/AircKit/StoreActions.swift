// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Arc's sidebar rules, as operations on SpacesStore. Each public method is one transaction.
// Requirement IDs refer to docs/spec.md §2.

/// Where something is dropped in the sidebar (SB-35).
public enum DropDestination: Hashable, Sendable {
    /// Into a profile's Favorites grid at `index`.
    case favorites(profileID: String, index: Int)
    /// Into a Space's pinned tree, inside `parentID` (nil = top level) at `index`.
    case pinned(spaceID: String, parentID: String?, index: Int)
    /// Into a Space's Today list at `index`.
    case today(spaceID: String, index: Int)
    /// SV-1: onto a Today row of `spaceID`: a tab (the two make a split) or a split (the tab joins it). `leading`: the
    /// left (or top) half of the row, which puts the dropped tab first (Arc ref §2.11).
    case split(spaceID: String, target: String, leading: Bool)
}

/// What is being dragged: a Today tab, a pinned item / Favorite (by its item), or a split's row.
public enum DragSource: Hashable, Sendable {
    case tab(String)
    case item(String)
    case split(String)
}

extension DropDestination {
    /// The position in the destination's list.
    public var index: Int {
        switch self {
        case .favorites(_, let i), .pinned(_, _, let i), .today(_, let i): i
        case .split: 0
        }
    }

    /// The same list at another position.
    public func with(index i: Int) -> DropDestination {
        switch self {
        case .favorites(let p, _): .favorites(profileID: p, index: i)
        case .pinned(let s, let parent, _): .pinned(spaceID: s, parentID: parent, index: i)
        case .today(let s, _): .today(spaceID: s, index: i)
        case .split: self
        }
    }
}

/// What ⌘W did (CB-2, SB-30).
public enum CloseOutcome: Equatable, Sendable {
    /// A Today tab went to the Archive.
    case archived(entryID: String)
    /// A pinned tab or Favorite was unloaded; its row stays.
    case unloaded
}

/// Where typed text goes for the current tab (SB-32).
public enum NavigationDecision: Equatable, Sendable {
    case loadInPlace
    case openTodayTab
}

public enum ProfileNameProblem: Equatable, Sendable {
    case empty, tooLong, taken
}

extension SpacesStore {
    public static let maxProfileNameLength = 40

    // MARK: - Profiles (SP-1, SP-11, SP-14)

    public func validateProfileName(_ name: String, excluding id: String? = nil) -> ProfileNameProblem? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return .empty }
        if n.count > Self.maxProfileNameLength { return .tooLong }
        if state.profiles.values.contains(where: { $0.id != id && $0.name.lowercased() == n.lowercased() }) {
            return .taken
        }
        return nil
    }

    /// Creates a profile. Its engine folder is fixed here and never reused.
    @discardableResult
    public func createProfile(name: String, emoji: String = "", color: RGBA? = nil) throws -> Profile {
        switch validateProfileName(name) {
        case .taken: throw StoreError.profileNameTaken
        case .empty, .tooLong: throw StoreError.invalidProfileName
        case nil: break
        }
        let palette = SpaceTheme.presets.map(\.color)
        let p = Profile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), emoji: emoji,
                        color: color ?? palette[state.profiles.count % palette.count], createdAt: now())
        try perform("New Profile") { put(p) }
        return p
    }

    public func updateProfile(_ id: String, _ change: (inout Profile) -> Void) throws {
        guard var p = profile(id) else { throw StoreError.notFound }
        let oldName = p.name
        change(&p)
        p.id = id
        if p.name != oldName {
            switch validateProfileName(p.name, excluding: id) {
            case .taken: throw StoreError.profileNameTaken
            case .empty, .tooLong: throw StoreError.invalidProfileName
            case nil: p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        try perform(nil) { put(p) }
    }

    /// Arc: "A Profile can only be deleted when no Space uses it." / "The default Profile can’t be deleted."
    public func canDeleteProfile(_ id: String) -> Result<Void, StoreError> {
        guard let p = profile(id) else { return .failure(.notFound) }
        if p.isDefault { return .failure(.cannotDeleteDefaultProfile) }
        if !spaces(usingProfile: id).isEmpty { return .failure(.profileInUse) }
        return .success(())
    }

    /// Deletes the profile, its Favorites and their tabs. The engine deletes the data folder.
    public func deleteProfile(_ id: String) throws {
        if case .failure(let e) = canDeleteProfile(id) { throw e }
        try perform(nil) {
            for f in favorites(ofProfile: id) { removeItemTree(f.id) }
            for t in state.tabs.values where t.profileID == id { remove(LiveTab.self, t.id) }
            for a in state.archive.values where a.profileID == id { remove(ArchiveEntry.self, a.id) }
            remove(Profile.self, id)
        }
    }

    // MARK: - Spaces (SP-2, SP-10, SP-13, SB-21, SB-23, SB-52)

    /// Creates a Space next to `after` (Arc inserts new Spaces beside the active one), or at the end.
    @discardableResult
    public func createSpace(name: String, icon: SpaceIcon? = nil, theme: SpaceTheme = .neutral,
                            profileID: String? = nil, after: String? = nil) throws -> Space {
        let spaces = orderedSpaces
        let order: Double
        if let after, let i = spaces.firstIndex(where: { $0.id == after }) {
            order = Ordering.between(spaces[i].order, i + 1 < spaces.count ? spaces[i + 1].order : nil)
        } else {
            order = Ordering.between(spaces.last?.order, nil)
        }
        let pid = profile(profileID)?.id ?? defaultProfile.id
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = Space(name: trimmed.isEmpty ? "Space \(spaces.count + 1)" : trimmed, icon: icon, theme: theme,
                      profileID: pid, order: order, createdAt: now())
        try perform("New Space") { put(s) }
        return s
    }

    public func updateSpace(_ id: String, _ change: (inout Space) -> Void) throws {
        guard var s = space(id) else { throw StoreError.notFound }
        change(&s)
        s.id = id
        try perform(nil) { put(s) }
    }

    /// Reorders Spaces (drag in the Space bar).
    public func moveSpace(_ id: String, to index: Int) throws {
        guard var s = space(id) else { throw StoreError.notFound }
        let others = orderedSpaces.filter { $0.id != id }.map(\.order)
        s.order = Ordering.insertion(at: index, in: others)
        try perform(nil) { put(s) }
    }

    /// SB-23: the last Space can't be deleted; Today tabs go to the Archive; ⌘Z undoes.
    public func deleteSpace(_ id: String) throws {
        guard space(id) != nil else { throw StoreError.notFound }
        guard state.spaces.count > 1 else { throw StoreError.cannotDeleteLastSpace }
        let spacesBefore = orderedSpaces
        try perform("Delete Space", undoable: true) {
            for x in splits(ofSpace: id) { remove(Split.self, x.id) }
            for t in todayTabs(ofSpace: id) { archive(t, reason: .spaceDeleted) }
            for root in pinnedRoots(ofSpace: id) { removeItemTree(root.id) }
            remove(Space.self, id)
            if windowState.selectedSpaceID == id, let i = spacesBefore.firstIndex(where: { $0.id == id }) {
                let next = i > 0 ? spacesBefore[i - 1] : spacesBefore[i + 1]
                updateWindowState { $0.selectedSpaceID = next.id }
            }
        }
    }

    /// SP-13: a tab can't change profile. The sidebar items stay; every open tab of the Space is
    /// reloaded in the new profile. Returns the tabs the engine must recreate.
    @discardableResult
    public func setProfile(ofSpace spaceID: String, to profileID: String) throws -> [String] {
        guard var s = space(spaceID), profile(profileID) != nil else { throw StoreError.notFound }
        guard s.profileID != profileID else { return [] }
        var reload: [String] = []
        try perform(nil) {
            s.profileID = profileID
            put(s)
            for var t in state.tabs.values where t.spaceID == spaceID {
                t.profileID = profileID
                put(t)
                reload.append(t.id)
            }
            // The last-active tab may have been the old profile's Favorite.
            if let last = s.lastActiveTabID, let t = tab(last), t.spaceID == nil, t.profileID != profileID {
                s.lastActiveTabID = nil
                put(s)
            }
        }
        return reload.sorted()
    }

    /// `deferred` writes the selection on the next `flush()` and notifies no one (the hot Space-switch path).
    public func selectSpace(_ id: String, deferred: Bool = false) {
        guard space(id) != nil else { return }
        updateWindowState(deferred: deferred) { $0.selectedSpaceID = id }
    }

    /// SP-20: ⌥⌘←/→ and the swipe: the neighbouring Space, or nil at the ends.
    public func adjacentSpace(to id: String, offset: Int) -> Space? {
        let spaces = orderedSpaces
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        let j = i + offset
        return spaces.indices.contains(j) ? spaces[j] : nil
    }

    // MARK: - Opening and activating tabs (SB-41, SB-42, SP-23)

    /// Opens a Today tab. New tabs go to the top of Today. A background link from a Today tab
    /// lines up after its opener (and after earlier links from the same opener); links from
    /// pinned tabs and Favorites go to the top.
    @discardableResult
    public func openTab(url: String, inSpace spaceID: String, openerID: String? = nil,
                        background: Bool = false, activate: Bool = true, title: String = "") throws -> LiveTab {
        guard let s = space(spaceID) else { throw StoreError.notFound }
        // Today's rows: a split is one row (SV-1).
        let today = todayRows(ofSpace: spaceID)
        var order = Ordering.between(nil, today.first.map(rowOrder))
        if background, let openerID, let opener = tab(openerID), opener.isToday, opener.spaceID == spaceID,
           let i = today.firstIndex(where: { $0.shows(openerID) }) {
            var j = i
            while j + 1 < today.count, today[j + 1].liveTab?.openerID == openerID, today[j + 1].split == nil { j += 1 }
            order = Ordering.between(rowOrder(today[j]), j + 1 < today.count ? rowOrder(today[j + 1]) : nil)
        }
        let t = LiveTab(profileID: s.profileID, spaceID: spaceID, url: url, title: title, order: order,
                        openerID: openerID, createdAt: now())
        try perform(nil) {
            put(t)
            if activate { markActive(t.id, inSpace: spaceID) }
        }
        return tab(t.id)!
    }

    /// The live tab for a pinned item or Favorite, created (unloaded, at the saved URL) if needed.
    @discardableResult
    public func openItem(_ itemID: String, inSpace spaceID: String, activate: Bool = true) throws -> LiveTab {
        // SV-2: a split (or one of its panes) opens with all its panes.
        if item(itemID)?.kind == .split || splitItem(ofPane: itemID) != nil { return try openSplitItem(itemID, inSpace: spaceID, activate: activate) }
        guard let item = item(itemID), item.kind == .tab, let saved = item.savedURL else { throw StoreError.notFound }
        if let t = liveTab(forItem: itemID) {
            if activate { try perform(nil) { markActive(t.id, inSpace: spaceID) } }
            return tab(t.id)!
        }
        let t: LiveTab
        switch item.container {
        case .pinned(let sid):
            t = LiveTab(profileID: profile(ofSpace: sid).id, spaceID: sid, itemID: itemID, url: saved,
                        title: item.pageTitle ?? "", faviconURL: item.faviconURL, createdAt: now())
        case .favorites(let pid):
            t = LiveTab(profileID: pid, spaceID: nil, itemID: itemID, url: saved, title: item.pageTitle ?? "",
                        faviconURL: item.faviconURL, createdAt: now())
        }
        try perform(nil) {
            put(t)
            if activate { markActive(t.id, inSpace: spaceID) }
        }
        return tab(t.id)!
    }

    /// Viewing a tab resets its archive timer and makes it the Space's last-shown tab.
    public func activate(_ tabID: String, inSpace spaceID: String) throws {
        guard tab(tabID) != nil, space(spaceID) != nil else { throw StoreError.notFound }
        // Written with the next flush: viewing a tab happens on every click and Space switch.
        try perform(nil, deferred: true) { markActive(tabID, inSpace: spaceID) }
    }

    func markActive(_ tabID: String, inSpace spaceID: String) {
        if var t = tab(tabID) { t.lastActiveAt = now(); put(t) }
        if var s = space(spaceID), s.lastActiveTabID != tabID { s.lastActiveTabID = tabID; put(s) }
    }

    /// The tab a Space shows when you switch to it (SP-23), if it still exists and belongs here.
    public func lastActiveTab(ofSpace spaceID: String) -> LiveTab? {
        guard let s = space(spaceID), let t = tab(s.lastActiveTabID) else { return nil }
        // SV-1: a tab in a split shows where the split's row is (a cross-Space pane isn't its own Space's to show).
        if let x = split(containing: t.id) { return showsSplit(x, inSpace: spaceID) ? t : nil }
        if t.spaceID == spaceID { return t }
        if t.spaceID == nil, t.profileID == s.profileID { return t }
        return nil
    }

    /// Engine updates (URL, title, favicon). Written lazily; call `flush()` periodically.
    public func updateTab(_ id: String, url: String? = nil, title: String? = nil, faviconURL: String? = nil,
                          muted: Bool? = nil) {
        guard var t = tab(id) else { return }
        let before = t
        if let url { t.url = url }
        if let title { t.title = title }
        if let faviconURL { t.faviconURL = faviconURL }
        if let muted { t.isMuted = muted }
        guard t != before else { return }
        try? perform(nil, deferred: true, contentOnly: true) {
            put(t)
            // A pinned item or Favorite remembers the title and icon of its saved page.
            if let iid = t.itemID, var item = item(iid), let saved = item.savedURL,
               !URLRules.isDrifted(saved: saved, current: t.url) {
                var changed = false
                if !t.title.isEmpty, item.pageTitle != t.title { item.pageTitle = t.title; changed = true }
                if let f = t.faviconURL, item.faviconURL != f { item.faviconURL = f; changed = true }
                if changed { put(item) }
            }
        }
    }

    // MARK: - Arc's pinned-tab rules (SB-12, SB-31, SB-32)

    /// True when a pinned tab or Favorite is away from its saved URL ("/" after the name).
    public func isDrifted(_ tabID: String) -> Bool {
        guard let t = tab(tabID), let saved = item(t.itemID)?.savedURL else { return false }
        return URLRules.isDrifted(saved: saved, current: t.url)
    }

    /// "Back to pinned URL": returns the URL the engine should load.
    @discardableResult
    public func resetToSavedURL(_ tabID: String) throws -> String {
        guard var t = tab(tabID), let saved = item(t.itemID)?.savedURL else { throw StoreError.notFound }
        t.url = saved
        try perform(nil) { put(t) }
        return saved
    }

    /// Right-click → "Replace with current URL".
    public func replaceSavedURL(ofItem itemID: String, with url: String, title: String? = nil) throws {
        guard var i = item(itemID), i.kind == .tab else { throw StoreError.notFound }
        i.savedURL = url
        if let title { i.pageTitle = title }
        try perform(nil) { put(i) }
    }

    /// SB-32: typing a new URL into a pinned tab or Favorite opens a Today tab instead.
    public func navigationDecision(forTab tabID: String?) -> NavigationDecision {
        guard let t = tab(tabID) else { return .openTodayTab }
        return t.isToday ? .loadInPlace : .openTodayTab
    }

    // MARK: - Closing, archiving, Clear, undo (SB-30, SB-40, SB-43, CB-2)

    /// ⌘W: a Today tab goes to the Archive (⌘Z restores it); a pinned tab or Favorite unloads
    /// and keeps its row, and opens at its saved URL next time.
    @discardableResult
    public func closeTab(_ tabID: String) throws -> CloseOutcome {
        guard let t = tab(tabID) else { throw StoreError.notFound }
        if t.isToday {
            var entryID = ""
            try perform("Close Tab", undoable: true) { entryID = archive(t, reason: .manual) }
            return .archived(entryID: entryID)
        }
        // SV-2: a pane of a pinned or Favorite split: the whole split's pages go; the split stays.
        if let s = splitItem(ofPane: t.itemID) {
            try perform("Close Tab", undoable: true) { unloadPanes(ofSplitItem: s.id) }
            return .unloaded
        }
        try perform("Close Tab", undoable: true) { remove(LiveTab.self, tabID) }
        return .unloaded
    }

    /// Removes a Today tab without archiving it: a popup that closed itself (e.g. a sign-in window).
    public func forgetTab(_ tabID: String) throws {
        guard let t = tab(tabID) else { return }
        try perform(nil) {
            remove(LiveTab.self, tabID)
            if let sid = t.spaceID, var s = space(sid), s.lastActiveTabID == tabID {
                s.lastActiveTabID = t.openerID.flatMap { tab($0) }?.id
                put(s)
            }
        }
    }

    @discardableResult
    func archive(_ t: LiveTab, reason: ArchiveReason) -> String {
        let entry = ArchiveEntry(tab: t, reason: reason, at: now())
        put(entry)
        remove(LiveTab.self, t.id)
        return entry.id
    }

    /// The tab to show after `tabID` closes: the next live tab below it in the sidebar, else the one
    /// above. Only tabs in the visible Space (its Favorites, pinned tabs and Today) count.
    public func tabToSelect(afterClosing tabID: String, inSpace spaceID: String) -> LiveTab? {
        let live = sidebarEntries(ofSpace: spaceID, skippingCollapsed: false).compactMap(\.liveTab)
        guard let i = live.firstIndex(where: { $0.id == tabID }) else { return lastActiveTab(ofSpace: spaceID) }
        if i + 1 < live.count { return live[i + 1] }
        if i > 0 { return live[i - 1] }
        return nil
    }

    /// SB-40: Clear archives every Today tab except the one shown. ⌘Z restores them.
    @discardableResult
    public func clearToday(inSpace spaceID: String, keeping visibleTabID: String?) throws -> [String] {
        // A split on screen stays whole (SV-1).
        let kept = Set(split(containing: visibleTabID)?.tabIDs ?? []).union([visibleTabID].compactMap { $0 })
        let victims = todayRowTabs(ofSpace: spaceID).filter { !kept.contains($0.id) }
        guard !victims.isEmpty else { return [] }
        try perform("Clear Today", undoable: true) {
            for t in victims { archive(t, reason: .clear) }
        }
        return victims.map(\.id)
    }

    /// Archives the given Today tabs as one undoable step (Clear Today and Archive Tabs Below, once their pages have
    /// closed: a page that asks "Leave site?" is archived on its own when the person leaves). Tabs that are gone or
    /// aren't Today tabs are left out.
    @discardableResult
    public func archiveTabs(_ ids: [String], reason: ArchiveReason, label: String) throws -> [String] {
        let victims = ids.compactMap { tab($0) }.filter(\.isToday)
        guard !victims.isEmpty else { return [] }
        try perform(label, undoable: true) {
            for t in victims { archive(t, reason: reason) }
        }
        return victims.map(\.id)
    }

    /// SB-43: archives Today tabs idle longer than their profile's interval. `protected` are tabs
    /// that must stay (the one shown, tabs playing audio).
    @discardableResult
    public func autoArchive(protected: Set<String> = []) throws -> [String] {
        try autoArchive(dueForAutoArchive(protected: protected), protected: protected)
    }

    /// The Today tabs idle longer than their profile's interval, longest idle first (SB-43). The app closes each one's
    /// page before it archives it: a page that would ask "Leave site?" isn't closed and stays for now.
    public func dueForAutoArchive(protected: Set<String> = []) -> [String] {
        let date = now()
        return state.tabs.values.filter { t in
            guard t.isToday, !protected.contains(t.id), let p = profile(t.profileID) else { return false }
            return date.timeIntervalSince(t.lastActiveAt) >= p.archiveAfter.seconds
        }.sorted { ($0.lastActiveAt, $0.id) < ($1.lastActiveAt, $1.id) }.map(\.id)
    }

    /// Archives `ids` as auto-archived, in one write (no undo step, as before). Only tabs still due and not
    /// `protected` (viewed again meanwhile, playing audio), unless `pageClosed`: a page that has already closed for
    /// auto-archiving goes to the Archive whatever happened since.
    @discardableResult
    public func autoArchive(_ ids: [String], protected: Set<String> = [], pageClosed: Bool = false) throws -> [String] {
        let due = pageClosed ? Set(ids) : Set(dueForAutoArchive(protected: protected))
        let victims = ids.filter(due.contains).compactMap { tab($0) }.filter(\.isToday)
        guard !victims.isEmpty else { return [] }
        try perform(nil) { for t in victims { archive(t, reason: .auto) } }
        return victims.map(\.id).sorted()
    }

    /// When the next Today tab becomes due for auto-archiving, or nil if none will. The app waits for exactly that
    /// moment with a one-shot timer instead of checking on a repeating one (MEM-6: no idle timers).
    public func nextAutoArchiveDate(protected: Set<String> = []) -> Date? {
        state.tabs.values.compactMap { t -> Date? in
            guard t.isToday, !protected.contains(t.id), let p = profile(t.profileID) else { return nil }
            return t.lastActiveAt.addingTimeInterval(p.archiveAfter.seconds)
        }.min()
    }

    /// Library → Archived Tabs → restore: back to the top of Today in its own Space, or in
    /// `fallbackSpaceID` if that Space is gone.
    @discardableResult
    public func restoreArchived(_ entryID: String, fallbackSpaceID: String) throws -> LiveTab {
        guard let e = state.archive[entryID] else { throw StoreError.notFound }
        let sid = space(e.spaceID)?.id ?? fallbackSpaceID
        guard let s = space(sid) else { throw StoreError.notFound }
        var t = e.tab
        t.spaceID = sid
        t.itemID = nil
        t.profileID = s.profileID
        t.order = topOfToday(sid)
        t.lastActiveAt = now()
        try perform(nil) {
            remove(ArchiveEntry.self, entryID)
            put(t)
        }
        return t
    }

    /// Library list, newest first.
    public var archivedEntries: [ArchiveEntry] {
        state.archive.values.sorted { ($0.archivedAt, $0.id) > ($1.archivedAt, $1.id) }
    }

    public func setMuted(_ tabID: String, _ muted: Bool) throws {
        guard var t = tab(tabID) else { throw StoreError.notFound }
        t.isMuted = muted
        try perform(nil) { put(t) }
    }

    /// Moves a Today tab to another Space ("Move to ›"). Returns true when the profile changes,
    /// which means the engine must reload the page in the new profile (SP-13).
    @discardableResult
    public func moveTab(_ tabID: String, toSpace spaceID: String) throws -> Bool {
        guard var t = tab(tabID), let s = space(spaceID) else { throw StoreError.notFound }
        let reload = t.profileID != s.profileID
        let fromSpace = t.spaceID
        try perform(nil) {
            if let iid = t.itemID { remove(Item.self, iid) }
            leaveSplit(tabID)
            t.itemID = nil
            t.spaceID = spaceID
            t.profileID = s.profileID
            t.order = topOfToday(spaceID, excluding: tabID)
            put(t)
            if let fromSpace, var from = space(fromSpace), from.lastActiveTabID == tabID {
                from.lastActiveTabID = nil
                put(from)
            }
        }
        return reload
    }

    @discardableResult
    public func duplicateTab(_ tabID: String) throws -> LiveTab {
        guard let t = tab(tabID) else { throw StoreError.notFound }
        let sid = t.spaceID ?? selectedSpace.id
        return try openTab(url: t.url, inSpace: sid, openerID: t.isToday ? t.id : nil, background: true,
                           activate: false, title: t.title)
    }

    // MARK: - Pinning, Favorites, folders, drag and drop (SB-14, SB-33, SB-35)

    /// ⌘D: pins a Today tab at the bottom of the pinned section, or unpins a pinned tab to the top
    /// of Today. Favorites go to Today too.
    public func togglePin(_ tabID: String, inSpace spaceID: String) throws {
        guard let t = tab(tabID) else { throw StoreError.notFound }
        // SV-2: ⌘D on a split pins or unpins the whole split.
        if let s = splitItem(ofPane: t.itemID) {
            try move(.item(s.id), to: .today(spaceID: spaceID, index: 0))
        } else if let x = state.splits.values.first(where: { $0.tabIDs.contains(tabID) }) {
            try move(.split(x.id), to: .pinned(spaceID: spaceID, parentID: nil, index: pinnedRoots(ofSpace: spaceID).count))
        } else if t.isToday {
            try move(.tab(tabID), to: .pinned(spaceID: spaceID, parentID: nil, index: pinnedRoots(ofSpace: spaceID).count))
        } else if let iid = t.itemID {
            try move(.item(iid), to: .today(spaceID: spaceID, index: 0))
        }
    }

    /// The one drag-and-drop operation. Indexes count the destination list as shown before the
    /// move. Returns the tabs that must reload because their profile changed.
    @discardableResult
    public func move(_ source: DragSource, to destination: DropDestination) throws -> [String] {
        if case .split(let id) = source { return try moveSplit(id, to: destination) }
        if case .item(let id) = source, item(id)?.kind == .split { return try moveSplitItem(id, to: destination) }
        if case .split(let sid, let target, let leading) = destination {
            guard case .tab(let id) = source else { throw StoreError.invalidMove }
            try dropIntoSplit(id, inSpace: sid, onto: target, leading: leading)
            return []
        }
        // Resolve the source to an item and/or a live tab.
        var srcItem: Item?
        var srcTab: LiveTab?
        switch source {
        case .item(let id):
            guard let i = item(id) else { throw StoreError.notFound }
            srcItem = i
            srcTab = liveTab(forItem: id)
        case .tab(let id):
            guard let t = tab(id) else { throw StoreError.notFound }
            srcTab = t
            srcItem = item(t.itemID)
        case .split:
            throw StoreError.invalidMove
        }
        var reload: [String] = []

        func bindTab(_ t: inout LiveTab, profileID: String) {
            if t.profileID != profileID { reload.append(t.id); t.profileID = profileID }
        }

        // SV-2: a pane dragged out of a pinned or Favorite split leaves it (a split down to one pane ends).
        let leavingSplit = splitItem(ofPane: srcItem?.id)
        try perform(nil) {
            // A tab that moves anywhere leaves its split (SV-1).
            if let t = srcTab { leaveSplit(t.id) }
            defer { if let s = leavingSplit { tidySplitItem(s.id) } }
            switch destination {
            case .split:
                throw StoreError.invalidMove
            case .favorites(let pid, let index):
                guard profile(pid) != nil else { throw StoreError.notFound }
                if srcItem?.kind == .folder { throw StoreError.invalidMove }
                let current = favorites(ofProfile: pid)
                let isTile = srcItem?.container == .favorites(profileID: pid) && srcItem?.parentID == nil
                if !isTile, current.count >= Self.maxFavorites {
                    throw StoreError.favoritesFull
                }
                let orders = siblingOrders(current, excluding: srcItem?.id, index: index)
                var i = srcItem ?? Item(kind: .tab, container: .favorites(profileID: pid), savedURL: srcTab?.url,
                                        pageTitle: srcTab?.title, faviconURL: srcTab?.faviconURL, createdAt: now())
                i.container = .favorites(profileID: pid)
                i.parentID = nil
                i.order = Ordering.insertion(at: orders.index, in: orders.orders)
                put(i)
                if var t = srcTab {
                    t.itemID = i.id
                    t.spaceID = nil
                    bindTab(&t, profileID: pid)
                    put(t)
                }

            case .pinned(let sid, let parentID, let index):
                guard let sp = space(sid) else { throw StoreError.notFound }
                if let parentID {
                    guard let parent = item(parentID), parent.kind == .folder,
                          parent.container == .pinned(spaceID: sid) else { throw StoreError.invalidMove }
                    if let src = srcItem, src.kind == .folder, isAncestor(src.id, of: parentID) {
                        throw StoreError.invalidMove
                    }
                }
                let siblings = children(of: .pinned(spaceID: sid), parent: parentID)
                let orders = siblingOrders(siblings, excluding: srcItem?.id, index: index)
                var i = srcItem ?? Item(kind: .tab, container: .pinned(spaceID: sid), savedURL: srcTab?.url,
                                        pageTitle: srcTab?.title, faviconURL: srcTab?.faviconURL, createdAt: now())
                let wasFavorite = i.isFavorite
                i.container = .pinned(spaceID: sid)
                i.parentID = parentID
                i.order = Ordering.insertion(at: orders.index, in: orders.orders)
                put(i)
                if i.kind == .folder { moveDescendants(of: i.id, to: .pinned(spaceID: sid), reload: &reload) }
                if var t = srcTab {
                    t.itemID = i.id
                    t.spaceID = sid
                    bindTab(&t, profileID: sp.profileID)
                    put(t)
                    if wasFavorite, var s = space(sid), s.lastActiveTabID == nil { s.lastActiveTabID = t.id; put(s) }
                }

            case .today(let sid, let index):
                guard let sp = space(sid) else { throw StoreError.notFound }
                if srcItem?.kind == .folder { throw StoreError.invalidMove }
                // Rows as shown: a split is one (SV-1); the index counts them before the move.
                let today = todayRows(ofSpace: sid)
                let others = today.filter { $0.id != srcTab?.id }
                var adjusted = index
                if let st = srcTab, let si = today.firstIndex(where: { $0.id == st.id }), si < index { adjusted -= 1 }
                let order = Ordering.insertion(at: min(adjusted, others.count), in: others.map(rowOrder))
                var t = srcTab ?? LiveTab(profileID: sp.profileID, spaceID: sid, url: srcItem?.savedURL ?? "",
                                          title: srcItem?.pageTitle ?? "", faviconURL: srcItem?.faviconURL,
                                          createdAt: now())
                if let si = srcItem { remove(Item.self, si.id) }
                t.itemID = nil
                t.spaceID = sid
                t.order = order
                bindTab(&t, profileID: sp.profileID)
                put(t)
            }
        }
        return reload
    }

    /// SB-36: a multi-selection dragged as one (Arc drags every selected row). The sources land at `destination` one
    /// after another, in the order given, in one undo step. Rows inside a selected folder go with the folder; a source
    /// that can't go there (a folder into Today) stays where it is; Favorites that can't take them all refuse the lot.
    /// Returns the tabs whose page must reload in another profile.
    @discardableResult
    public func move(_ sources: [DragSource], to destination: DropDestination) throws -> [String] {
        let list = topLevel(sources)
        if list.count <= 1 { return try list.first.map { try move($0, to: destination) } ?? [] }
        if case .favorites(let pid, _) = destination {
            let incoming = list.filter { s in sourceItemID(s).flatMap(item)?.container != .favorites(profileID: pid) }
            if favorites(ofProfile: pid).count + incoming.count > Self.maxFavorites { throw StoreError.favoritesFull }
        }
        var reload: [String] = []
        try perform("Move", undoable: true) {
            var dest = destination
            for s in list {
                // Where this one ends up: the index counts the row itself if it's already in that list above the drop.
                let i = dest.index
                let landed = position(of: s, in: dest).map { $0 < i ? i - 1 : i } ?? i
                do { reload += try move(s, to: dest) } catch StoreError.invalidMove { continue } catch StoreError.splitFull { continue }
                dest = dest.with(index: landed + 1)
            }
        }
        return reload
    }

    /// ⌥-drag of a multi-selection: a copy of each source at `destination`, in order, in one undo step. Returns the new
    /// items' or tabs' IDs.
    @discardableResult
    public func copy(_ sources: [DragSource], to destination: DropDestination) throws -> [String] {
        let list = topLevel(sources)
        if list.count <= 1 { return try list.first.map { [try copy($0, to: destination)] } ?? [] }
        if case .favorites(let pid, _) = destination, favorites(ofProfile: pid).count + list.count > Self.maxFavorites {
            throw StoreError.favoritesFull
        }
        var made: [String] = []
        try perform("Duplicate", undoable: true) {
            var dest = destination
            for s in list {
                do { made.append(try copy(s, to: dest)) } catch StoreError.invalidMove { continue }
                dest = dest.with(index: dest.index + 1)
            }
        }
        return made
    }

    /// The item behind a drag source (a Today tab has none).
    private func sourceItemID(_ s: DragSource) -> String? {
        switch s {
        case .item(let id): id
        case .tab(let id): tab(id)?.itemID
        case .split: nil
        }
    }

    /// `sources` without the ones inside another source's folder (they move with it), duplicates dropped.
    private func topLevel(_ sources: [DragSource]) -> [DragSource] {
        var seen = Set<DragSource>()
        let unique = sources.filter { seen.insert($0).inserted }
        let folders = Set(unique.compactMap(sourceItemID).filter { item($0)?.kind == .folder })
        return unique.filter { s in
            guard let id = sourceItemID(s) else { return true }
            var parent = item(id)?.parentID
            var guardCount = 0
            while let p = parent, guardCount < 256 {
                if folders.contains(p) { return false }
                parent = item(p)?.parentID
                guardCount += 1
            }
            return true
        }
    }

    /// Where `source` is in `destination`'s list now, if it's in that list.
    private func position(of source: DragSource, in destination: DropDestination) -> Int? {
        switch destination {
        case .favorites(let pid, _):
            guard let id = sourceItemID(source) else { return nil }
            return favorites(ofProfile: pid).firstIndex { $0.id == id }
        case .pinned(let sid, let parent, _):
            guard let id = sourceItemID(source) else { return nil }
            return children(of: .pinned(spaceID: sid), parent: parent).firstIndex { $0.id == id }
        case .today(let sid, _):
            let id: String
            switch source {
            case .tab(let t): id = t
            case .split(let x): id = x
            case .item: return nil
            }
            return todayRows(ofSpace: sid).firstIndex { $0.id == id }
        case .split:
            return nil
        }
    }

    /// ⌥-drag (Arc, SB-35): a copy of the dragged Today tab, pinned item, Favorite or folder lands at `destination`;
    /// the source stays where it was. The copy has no live page yet: a pinned copy or Favorite loads when opened, a
    /// Today copy is a new tab at the same address. One undo step. Returns the new item's or tab's ID.
    @discardableResult
    public func copy(_ source: DragSource, to destination: DropDestination) throws -> String {
        var srcItem: Item?
        var srcTab: LiveTab?
        switch source {
        case .item(let id):
            guard let i = item(id) else { throw StoreError.notFound }
            srcItem = i
            srcTab = liveTab(forItem: id)
        case .tab(let id):
            guard let t = tab(id) else { throw StoreError.notFound }
            srcTab = t
            srcItem = item(t.itemID)
        case .split:
            throw StoreError.invalidMove
        }
        if case .split = destination { throw StoreError.invalidMove }
        // SV-2: a pinned or Favorite split copies as a split (not into Today); a pane copies as a tab of its own.
        if srcItem?.kind == .split, case .today = destination { throw StoreError.invalidMove }
        // A copy of a pinned item keeps its saved address and name; a Today tab's copy takes the page it's on.
        func copiedItem(_ container: ItemContainer) -> Item {
            if var c = srcItem {
                c.id = newID()
                c.createdAt = now()
                c.container = container
                return c
            }
            return Item(kind: .tab, container: container, savedURL: srcTab?.url, pageTitle: srcTab?.title,
                        faviconURL: srcTab?.faviconURL, createdAt: now())
        }
        var created = ""
        try perform("Duplicate", undoable: true) {
            switch destination {
            case .split:
                throw StoreError.invalidMove
            case .favorites(let pid, let index):
                guard profile(pid) != nil else { throw StoreError.notFound }
                if srcItem?.kind == .folder { throw StoreError.invalidMove }
                let current = favorites(ofProfile: pid)
                if current.count >= Self.maxFavorites { throw StoreError.favoritesFull }
                var i = copiedItem(.favorites(profileID: pid))
                i.parentID = nil
                i.order = Ordering.insertion(at: min(index, current.count), in: current.map(\.order))
                put(i)
                if let src = srcItem, src.kind == .split { copyPanes(from: src.id, to: i.id, container: .favorites(profileID: pid)) }
                created = i.id
            case .pinned(let sid, let parentID, let index):
                guard space(sid) != nil else { throw StoreError.notFound }
                if let parentID {
                    guard let parent = item(parentID), parent.kind == .folder,
                          parent.container == .pinned(spaceID: sid) else { throw StoreError.invalidMove }
                }
                let siblings = children(of: .pinned(spaceID: sid), parent: parentID)
                var i = copiedItem(.pinned(spaceID: sid))
                i.parentID = parentID
                i.order = Ordering.insertion(at: min(index, siblings.count), in: siblings.map(\.order))
                put(i)
                if let src = srcItem, src.kind == .folder { copyChildren(from: src.id, to: i.id, container: .pinned(spaceID: sid)) }
                if let src = srcItem, src.kind == .split { copyPanes(from: src.id, to: i.id, container: .pinned(spaceID: sid)) }
                created = i.id
            case .today(let sid, let index):
                guard let sp = space(sid) else { throw StoreError.notFound }
                if srcItem?.kind == .folder { throw StoreError.invalidMove }
                let today = todayRows(ofSpace: sid)
                var t = LiveTab(profileID: sp.profileID, spaceID: sid, url: srcTab?.url ?? srcItem?.savedURL ?? "",
                                title: srcTab?.title ?? srcItem?.pageTitle ?? "", faviconURL: srcTab?.faviconURL ?? srcItem?.faviconURL,
                                createdAt: now())
                t.order = Ordering.insertion(at: min(index, today.count), in: today.map(rowOrder))
                put(t)
                created = t.id
            }
        }
        return created
    }

    /// Orders of `siblings` without the moving item, and the insertion index adjusted for it.
    func siblingOrders(_ siblings: [Item], excluding id: String?, index: Int) -> (orders: [Double], index: Int) {
        var i = index
        if let id, let si = siblings.firstIndex(where: { $0.id == id }), si < index { i -= 1 }
        return (siblings.filter { $0.id != id }.map(\.order), i)
    }

    private func isAncestor(_ ancestor: String, of id: String) -> Bool {
        var cur: String? = id
        var guardCount = 0
        while let c = cur, guardCount < 256 {
            if c == ancestor { return true }
            cur = item(c)?.parentID
            guardCount += 1
        }
        return false
    }

    func moveDescendants(of folderID: String, to container: ItemContainer, reload: inout [String]) {
        for var child in state.items.values where child.parentID == folderID {
            child.container = container
            put(child)
            if var t = liveTab(forItem: child.id) {
                // SV-2: a split's panes go with it, into Pinned or Favorites.
                let (sid, pid) = binding(of: container)
                t.spaceID = sid
                if t.profileID != pid { t.profileID = pid; reload.append(t.id) }
                put(t)
            }
            if child.kind != .tab { moveDescendants(of: child.id, to: container, reload: &reload) }
        }
    }

    /// SB-33: New Folder (from the Space menu, the + menu, or a multi-selection).
    @discardableResult
    public func createFolder(named name: String = "New Folder", inSpace spaceID: String, parentID: String? = nil,
                             index: Int? = nil, containing sources: [DragSource] = []) throws -> Item {
        guard space(spaceID) != nil else { throw StoreError.notFound }
        let siblings = children(of: .pinned(spaceID: spaceID), parent: parentID)
        let folder = Item(kind: .folder, container: .pinned(spaceID: spaceID), parentID: parentID,
                          order: Ordering.insertion(at: index ?? siblings.count, in: siblings.map(\.order)),
                          title: name, createdAt: now())
        try perform("New Folder") {
            put(folder)
            for (n, src) in sources.enumerated() {
                try move(src, to: .pinned(spaceID: spaceID, parentID: folder.id, index: n))
            }
        }
        return item(folder.id)!
    }

    public func renameItem(_ id: String, to title: String?) throws {
        guard var i = item(id) else { throw StoreError.notFound }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        i.title = (t?.isEmpty ?? true) ? (i.kind == .folder ? "Folder" : nil) : t
        try perform(nil) { put(i) }
    }

    public func setItemIcon(_ id: String, to emoji: String?) throws {
        guard var i = item(id) else { throw StoreError.notFound }
        i.icon = emoji
        try perform(nil) { put(i) }
    }

    /// Folder open/close on press (SB-33).
    public func toggleFolder(_ id: String) throws {
        guard var i = item(id), i.kind == .folder else { throw StoreError.notFound }
        i.isCollapsed.toggle()
        try perform(nil) { put(i) }
    }

    /// Removes a pinned item, Favorite or folder (with everything inside). ⌘Z restores it.
    public func deleteItem(_ id: String) throws {
        guard item(id) != nil else { throw StoreError.notFound }
        try perform("Delete", undoable: true) { removeItemTree(id) }
    }

    /// Duplicate a pinned item or folder just below itself.
    @discardableResult
    public func duplicateItem(_ id: String) throws -> Item {
        guard let src = item(id) else { throw StoreError.notFound }
        let siblings = children(of: src.container, parent: src.parentID)
        let i = siblings.firstIndex(where: { $0.id == id }) ?? siblings.count - 1
        if src.isFavorite, siblings.count >= Self.maxFavorites { throw StoreError.favoritesFull }
        var copy = src
        copy.id = newID()
        copy.createdAt = now()
        copy.order = Ordering.between(src.order, i + 1 < siblings.count ? siblings[i + 1].order : nil)
        try perform(nil) {
            put(copy)
            if src.kind == .folder { copyChildren(from: src.id, to: copy.id) }
            if src.kind == .split { copyPanes(from: src.id, to: copy.id, container: src.container) }
        }
        return item(copy.id) ?? copy
    }

    private func copyChildren(from: String, to: String, container: ItemContainer? = nil) {
        for child in state.items.values where child.parentID == from {
            var c = child
            c.id = newID()
            c.parentID = to
            if let container { c.container = container }
            put(c)
            if child.kind == .folder { copyChildren(from: child.id, to: c.id, container: container) }
            if child.kind == .split { copyPanes(from: child.id, to: c.id, container: container ?? child.container) }
        }
    }

    /// "Copy all links" of a folder, nested folders included, in display order.
    public func allLinks(inFolder id: String) -> [String] {
        guard let f = item(id) else { return [] }
        var out: [String] = []
        for c in children(of: f.container, parent: id) {
            if c.kind == .folder { out += allLinks(inFolder: c.id) } else if let u = c.savedURL { out.append(u) }
        }
        return out
    }
}
