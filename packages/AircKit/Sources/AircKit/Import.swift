// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Applying an import (IM-1) to SpacesStore. The importer (packages/AircImport) reads Arc's files into a plan; the
// app turns that plan into an `ImportBlueprint`, and `applyImport` writes it here. Everything is keyed on the
// source's own IDs, so running the same import again updates what it made instead of duplicating it.

/// What an import brings in, independent of where it came from.
public struct ImportBlueprint: Sendable, Equatable {
    public struct Profile: Sendable, Equatable {
        /// Stable source key, e.g. "arc-profile:Profile 1".
        public var sourceID: String
        public var name: String
        public var emoji: String
        public var color: RGBA?
        /// The source's default profile maps onto Airc's default profile instead of creating one.
        public var isSourceDefault: Bool

        public init(sourceID: String, name: String, emoji: String = "", color: RGBA? = nil, isSourceDefault: Bool = false) {
            self.sourceID = sourceID
            self.name = name
            self.emoji = emoji
            self.color = color
            self.isSourceDefault = isSourceDefault
        }
    }

    public struct Tab: Sendable, Equatable {
        public var sourceID: String
        public var url: String
        /// The user's custom name, if they renamed it.
        public var title: String?
        /// The last page title seen.
        public var pageTitle: String?
        public var lastActiveAt: Date?

        public init(sourceID: String, url: String, title: String? = nil, pageTitle: String? = nil, lastActiveAt: Date? = nil) {
            self.sourceID = sourceID
            self.url = url
            self.title = title
            self.pageTitle = pageTitle
            self.lastActiveAt = lastActiveAt
        }
    }

    public struct Folder: Sendable, Equatable {
        public var sourceID: String
        public var title: String
        public var children: [Node]

        public init(sourceID: String, title: String, children: [Node]) {
            self.sourceID = sourceID
            self.title = title
            self.children = children
        }
    }

    /// SV-2: a split view in Arc's pinned tabs or Favorites (2–4 tabs), imported as a pinned or Favorite split.
    public struct SplitView: Sendable, Equatable {
        public var sourceID: String
        public var title: String?
        public var axis: SplitAxis
        /// Each tab's share, in tab order (empty: equal shares).
        public var shares: [Double]
        /// The source ID of the tab that had the keyboard.
        public var focusedSourceID: String?
        public var tabs: [Tab]

        public init(sourceID: String, title: String? = nil, axis: SplitAxis = .horizontal, shares: [Double] = [],
                    focusedSourceID: String? = nil, tabs: [Tab]) {
            self.sourceID = sourceID
            self.title = title
            self.axis = axis
            self.shares = shares
            self.focusedSourceID = focusedSourceID
            self.tabs = tabs
        }
    }

    public indirect enum Node: Sendable, Equatable {
        case tab(Tab)
        case folder(Folder)
        case split(SplitView)

        public var tabCount: Int {
            switch self {
            case .tab: 1
            case .folder(let f): f.children.reduce(0) { $0 + $1.tabCount }
            case .split(let x): x.tabs.count
            }
        }

        public var folderCount: Int {
            switch self {
            case .tab, .split: 0
            case .folder(let f): 1 + f.children.reduce(0) { $0 + $1.folderCount }
            }
        }

        /// The tabs, in order (a folder's and a split's included).
        public var tabs: [Tab] {
            switch self {
            case .tab(let t): [t]
            case .folder(let f): f.children.flatMap(\.tabs)
            case .split(let x): x.tabs
            }
        }
    }

    public struct Space: Sendable, Equatable {
        public var sourceID: String
        public var name: String
        public var icon: SpaceIcon?
        public var theme: SpaceTheme
        public var profileSourceID: String
        public var pinned: [Node]
        public var today: [Tab]

        public init(sourceID: String, name: String, icon: SpaceIcon? = nil, theme: SpaceTheme = .neutral,
                    profileSourceID: String, pinned: [Node] = [], today: [Tab] = []) {
            self.sourceID = sourceID
            self.name = name
            self.icon = icon
            self.theme = theme
            self.profileSourceID = profileSourceID
            self.pinned = pinned
            self.today = today
        }

        public var pinnedTabCount: Int { pinned.reduce(0) { $0 + $1.tabCount } }
    }

    public var profiles: [Profile]
    public var spaces: [Space]
    /// Favorites per profile source ID, in order.
    public var favorites: [String: [Tab]]
    /// SV-2: Favorites per profile source ID with their splits kept, in order. Where a profile has an entry here, it
    /// is what's imported; `favorites` then lists the same tabs flat.
    public var favoriteNodes: [String: [Node]]

    public init(profiles: [Profile], spaces: [Space], favorites: [String: [Tab]] = [:], favoriteNodes: [String: [Node]] = [:]) {
        self.profiles = profiles
        self.spaces = spaces
        self.favorites = favorites
        self.favoriteNodes = favoriteNodes
    }

    /// What a profile's Favorites import as: its nodes (splits kept), else its tabs.
    public func favoriteEntries(_ profileSourceID: String) -> [Node] {
        favoriteNodes[profileSourceID] ?? (favorites[profileSourceID] ?? []).map { .tab($0) }
    }

    /// Profiles that at least one Space or Favorite uses, in source order.
    public var usedProfiles: [Profile] {
        let used = Set(spaces.map(\.profileSourceID)).union(favorites.filter { !$0.value.isEmpty }.keys)
            .union(favoriteNodes.filter { !$0.value.isEmpty }.keys)
        return profiles.filter { used.contains($0.sourceID) }
    }

    public var pinnedTabCount: Int { spaces.reduce(0) { $0 + $1.pinnedTabCount } }
    public var todayTabCount: Int { spaces.reduce(0) { $0 + $1.today.count } }
    public var favoriteCount: Int {
        Set(favorites.keys).union(favoriteNodes.keys).reduce(0) { $0 + min(favoriteEntries($1).count, SpacesStore.maxFavorites) }
    }
}

/// What `applyImport` did.
public struct ImportResult: Sendable, Equatable {
    public var profilesCreated: [String] = []
    public var profilesUpdated = 0
    public var spacesCreated = 0
    public var spacesUpdated = 0
    public var pinnedTabs = 0
    public var folders = 0
    public var favorites = 0
    public var todayTabs = 0
    /// Favorites past the 12 a profile can hold.
    public var favoritesSkipped = 0
    /// SV-2: splits imported as splits (pinned and Favorites).
    public var splits = 0
    /// Source profile key → Airc profile ID.
    public var profileIDs: [String: String] = [:]
    /// Source Space key → Airc Space ID.
    public var spaceIDs: [String: String] = [:]

    public init() {}

    public mutating func merge(_ o: ImportResult) {
        profilesCreated += o.profilesCreated
        profilesUpdated += o.profilesUpdated
        spacesCreated += o.spacesCreated
        spacesUpdated += o.spacesUpdated
        pinnedTabs += o.pinnedTabs
        folders += o.folders
        favorites += o.favorites
        todayTabs += o.todayTabs
        favoritesSkipped += o.favoritesSkipped
        splits += o.splits
        profileIDs.merge(o.profileIDs) { $1 }
        spaceIDs.merge(o.spaceIDs) { $1 }
    }
}

public struct ImportOptions: Sendable, Equatable {
    /// Only these Space source IDs (nil = all).
    public var spaces: Set<String>?
    public var includeToday: Bool
    public var includeFavorites: Bool

    public init(spaces: Set<String>? = nil, includeToday: Bool = true, includeFavorites: Bool = true) {
        self.spaces = spaces
        self.includeToday = includeToday
        self.includeFavorites = includeFavorites
    }
}

extension SpacesStore {
    /// A fresh install's untouched Space: the only one, never imported, nothing in it. The first imported Space
    /// takes it over instead of leaving an empty "Personal" behind.
    var pristineSpaceID: String? {
        guard state.spaces.count == 1, let s = state.spaces.values.first, s.sourceID == nil else { return nil }
        guard todayTabs(ofSpace: s.id).isEmpty, pinnedRoots(ofSpace: s.id).isEmpty else { return nil }
        return s.id
    }

    public func profile(sourceID: String) -> Profile? { state.profiles.values.first { $0.sourceID == sourceID } }
    public func space(sourceID: String) -> Space? { state.spaces.values.first { $0.sourceID == sourceID } }

    /// Writes an import into the store in one transaction (one undo step, "Import"). Idempotent: profiles, Spaces,
    /// items and Today tabs are matched on their source IDs and updated in place; nothing the user made is removed.
    /// The source's default profile becomes Airc's default profile. New profiles get fresh engine folders; the
    /// caller loads them (`ImportResult.profilesCreated`).
    @discardableResult
    public func applyImport(_ b: ImportBlueprint, options: ImportOptions = .init()) throws -> ImportResult {
        var r = ImportResult()
        let spaces = b.spaces.filter { options.spaces?.contains($0.sourceID) ?? true }
        var neededProfiles = Set(spaces.map(\.profileSourceID))
        if options.includeFavorites {
            neededProfiles.formUnion(b.favorites.filter { !$0.value.isEmpty }.keys)
            neededProfiles.formUnion(b.favoriteNodes.filter { !$0.value.isEmpty }.keys)
        }
        // Favorites only come along with a profile one of the chosen Spaces uses.
        if options.spaces != nil { neededProfiles = Set(spaces.map(\.profileSourceID)) }
        try perform("Import", undoable: true) {
            var itemIDs = Dictionary(state.items.values.compactMap { i in i.sourceID.map { ($0, i.id) } }, uniquingKeysWith: { a, _ in a })
            var tabIDs = Dictionary(state.tabs.values.compactMap { t in t.sourceID.map { ($0, t.id) } }, uniquingKeysWith: { a, _ in a })
            // Pinned items this import has placed: a source ID that comes again (a crafted bookmarks file) gets an item
            // of its own instead of moving one already placed, which could make a folder its own parent or ancestor.
            var placed = Set<String>()
            // Profiles.
            var taken = Set(state.profiles.values.map { $0.name.lowercased() })
            for p in b.profiles where neededProfiles.contains(p.sourceID) {
                if var existing = profile(sourceID: p.sourceID) {
                    existing.emoji = existing.emoji.isEmpty ? p.emoji : existing.emoji
                    put(existing)
                    r.profileIDs[p.sourceID] = existing.id
                    r.profilesUpdated += 1
                } else if p.isSourceDefault, var def = state.profiles.values.first(where: \.isDefault), def.sourceID == nil {
                    def.sourceID = p.sourceID
                    let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, name.lowercased() != "default", !taken.contains(name.lowercased()) {
                        taken.remove(def.name.lowercased())
                        def.name = String(name.prefix(Self.maxProfileNameLength))
                        taken.insert(def.name.lowercased())
                    }
                    if def.emoji.isEmpty { def.emoji = p.emoji }
                    if let c = p.color { def.color = c }
                    put(def)
                    r.profileIDs[p.sourceID] = def.id
                    r.profilesUpdated += 1
                } else {
                    var name = String(p.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxProfileNameLength))
                    if name.isEmpty { name = "Profile" }
                    let base = name
                    var n = 2
                    while taken.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
                    taken.insert(name.lowercased())
                    let created = Profile(name: name, emoji: p.emoji, color: p.color ?? RGBA(hex: "7EB6D5")!,
                                          createdAt: now(), sourceID: p.sourceID)
                    put(created)
                    r.profileIDs[p.sourceID] = created.id
                    r.profilesCreated.append(created.id)
                }
            }
            func profileID(_ source: String) -> String { r.profileIDs[source] ?? defaultProfile.id }

            // Favorites, per profile.
            if options.includeFavorites {
                for source in Set(b.favorites.keys).union(b.favoriteNodes.keys).sorted() where neededProfiles.contains(source) {
                    let pid = profileID(source)
                    let container = ItemContainer.favorites(profileID: pid)
                    for node in b.favoriteEntries(source) {
                        // SV-2: a Favorite split is one tile.
                        if case .split(let x) = node, x.tabs.count >= 2 {
                            if item(itemIDs[x.sourceID])?.kind != .split, children(of: container, parent: nil).count >= Self.maxFavorites {
                                r.favoritesSkipped += 1
                                continue
                            }
                            applySplit(x, container: container, parentID: nil, order: nil, itemIDs: &itemIDs)
                            r.favorites += 1
                            r.splits += 1
                            continue
                        }
                        guard let t = node.tabs.first else { continue }
                        let key = t.sourceID
                        if var existing = item(itemIDs[key]) {
                            existing.savedURL = t.url
                            existing.title = t.title
                            if let pt = t.pageTitle { existing.pageTitle = pt }
                            put(existing)
                            r.favorites += 1
                            continue
                        }
                        let siblings = children(of: container, parent: nil)
                        guard siblings.count < Self.maxFavorites else { r.favoritesSkipped += 1; continue }
                        let fav = Item(kind: .tab, container: container, order: Ordering.between(siblings.last?.order, nil),
                                       savedURL: t.url, title: t.title, pageTitle: t.pageTitle, createdAt: now(), sourceID: key)
                        put(fav)
                        itemIDs[key] = fav.id
                        r.favorites += 1
                    }
                }
            }

            // Spaces, their pinned trees and Today tabs.
            var pristine = pristineSpaceID
            for s in spaces {
                let pid = profileID(s.profileSourceID)
                var space: Space
                if var existing = self.space(sourceID: s.sourceID) {
                    existing.name = s.name
                    existing.icon = s.icon
                    existing.theme = s.theme
                    if existing.profileID != pid {
                        existing.profileID = pid
                        for var t in state.tabs.values where t.spaceID == existing.id { t.profileID = pid; put(t) }
                    }
                    space = existing
                    r.spacesUpdated += 1
                } else if let reuse = pristine, var fresh = self.space(reuse) {
                    pristine = nil
                    fresh.name = s.name
                    fresh.icon = s.icon
                    fresh.theme = s.theme
                    fresh.profileID = pid
                    fresh.sourceID = s.sourceID
                    space = fresh
                    r.spacesCreated += 1
                } else {
                    space = Space(name: s.name, icon: s.icon, theme: s.theme, profileID: pid,
                                  order: Ordering.between(orderedSpaces.last?.order, nil), createdAt: now(), sourceID: s.sourceID)
                    r.spacesCreated += 1
                }
                put(space)
                r.spaceIDs[s.sourceID] = space.id
                applyPinned(s.pinned, spaceID: space.id, parentID: nil, itemIDs: &itemIDs, placed: &placed, result: &r)
                if options.includeToday {
                    for (i, t) in s.today.enumerated() {
                        if var existing = tab(tabIDs[t.sourceID]) {
                            existing.url = t.url
                            if let title = t.title ?? t.pageTitle { existing.title = title }
                            put(existing)
                        } else {
                            let active = t.lastActiveAt ?? now()
                            let live = LiveTab(profileID: pid, spaceID: space.id, url: t.url, title: t.title ?? t.pageTitle ?? "",
                                               order: Double(i), createdAt: active, lastActiveAt: active, sourceID: t.sourceID)
                            put(live)
                            tabIDs[t.sourceID] = live.id
                        }
                        r.todayTabs += 1
                    }
                }
            }
        }
        return r
    }

    private func applyPinned(_ nodes: [ImportBlueprint.Node], spaceID: String, parentID: String?,
                             itemIDs: inout [String: String], placed: inout Set<String>, result r: inout ImportResult) {
        let container = ItemContainer.pinned(spaceID: spaceID)
        /// The item `sourceID` had before, if it's a `kind` and this import hasn't placed it yet.
        func reusable(_ sourceID: String, _ kind: ItemKind) -> Item? {
            guard let existing = item(itemIDs[sourceID]), existing.kind == kind, !placed.contains(existing.id) else { return nil }
            return existing
        }
        for (index, node) in nodes.enumerated() {
            switch node {
            case .tab(let t):
                if var existing = reusable(t.sourceID, .tab) {
                    existing.container = container
                    existing.parentID = parentID
                    existing.order = Double(index)
                    existing.savedURL = t.url
                    existing.title = t.title
                    if let pt = t.pageTitle { existing.pageTitle = pt }
                    put(existing)
                    placed.insert(existing.id)
                } else {
                    let pinned = Item(kind: .tab, container: container, parentID: parentID, order: Double(index), savedURL: t.url,
                                      title: t.title, pageTitle: t.pageTitle, createdAt: now(), sourceID: t.sourceID)
                    put(pinned)
                    itemIDs[t.sourceID] = pinned.id
                    placed.insert(pinned.id)
                }
                r.pinnedTabs += 1
            case .split(let x) where x.tabs.count < 2:
                applyPinned(x.tabs.map { .tab($0) }, spaceID: spaceID, parentID: parentID, itemIDs: &itemIDs, placed: &placed, result: &r)
            case .split(let x):
                applySplit(x, container: container, parentID: parentID, order: Double(index), itemIDs: &itemIDs)
                r.pinnedTabs += x.tabs.count
                r.splits += 1
            case .folder(let f):
                let id: String
                if var existing = reusable(f.sourceID, .folder) {
                    existing.container = container
                    existing.parentID = parentID
                    existing.order = Double(index)
                    existing.title = f.title
                    put(existing)
                    id = existing.id
                } else {
                    let folder = Item(kind: .folder, container: container, parentID: parentID, order: Double(index),
                                      title: f.title, createdAt: now(), sourceID: f.sourceID)
                    put(folder)
                    itemIDs[f.sourceID] = folder.id
                    id = folder.id
                }
                placed.insert(id)
                r.folders += 1
                applyPinned(f.children, spaceID: spaceID, parentID: id, itemIDs: &itemIDs, placed: &placed, result: &r)
            }
        }
    }

    /// SV-2: one imported split as a split item with a pane item per tab, matched on source IDs like everything else.
    /// `order` nil: after the container's last item.
    private func applySplit(_ x: ImportBlueprint.SplitView, container: ItemContainer, parentID: String?, order: Double?,
                            itemIDs: inout [String: String]) {
        var s: Item
        if let existing = item(itemIDs[x.sourceID]), existing.kind == .split {
            s = existing
        } else {
            s = Item(kind: .split, container: container, createdAt: now(), sourceID: x.sourceID)
            itemIDs[x.sourceID] = s.id
        }
        s.container = container
        s.parentID = parentID
        s.order = order ?? (item(s.id) == nil ? Ordering.between(children(of: container, parent: parentID).last?.order, nil) : s.order)
        s.title = x.title
        var layout = SplitLayout(axis: x.axis)
        for (k, t) in x.tabs.prefix(Split.maxPanes).enumerated() {
            var p = item(itemIDs[t.sourceID]) ?? Item(kind: .tab, container: container, createdAt: now(), sourceID: t.sourceID)
            p.container = container
            p.parentID = s.id
            p.order = Double(k)
            p.savedURL = t.url
            p.title = t.title
            if let pt = t.pageTitle { p.pageTitle = pt }
            put(p)
            itemIDs[t.sourceID] = p.id
            if x.shares.indices.contains(k), x.shares[k] > 0 { layout.shares[p.id] = x.shares[k] }
            if t.sourceID == x.focusedSourceID { layout.focusedItemID = p.id }
        }
        s.splitLayout = layout
        put(s)
    }
}
