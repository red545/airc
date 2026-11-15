// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// S09/S11: the targets of a Favorite's, a folder's and a multi-selection's "Move to ›". Arc 1.171's move menu
/// (SidebarMenu+MoveMenu) lists Spaces, and a Favorite's adds a choice of profile ("Submenu to chose which profile to
/// move Favorite(s) to"); this one groups both by profile:
///   - first the source profile's Spaces (a folder's own Space left out: it's already there);
///   - then one section per other profile that has a Space, headed by its name: for Favorites that profile's Favorites
///     first, then its Spaces.
/// Rows of another profile are `crossProfile`: their pages reopen with that profile's logins and cookies.
public struct MoveToPlan: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case space(String)
        case favorites(profileID: String)
    }

    public struct Row: Equatable, Sendable {
        public var target: Target
        public var title: String
        public var crossProfile: Bool
    }

    public struct Section: Equatable, Sendable {
        public var profileID: String
        /// The profile's name; nil for the source profile's section, and when only one profile has Spaces.
        public var header: String?
        public var rows: [Row]
    }

    public var sections: [Section]

    public var rows: [Row] { sections.flatMap(\.rows) }
    public var isEmpty: Bool { rows.isEmpty }

    /// The tooltip of a row that changes profile (Arc shows none; its move silently reloads the page).
    public static let crossProfileTooltip =
        "Opens in the other Profile: its logins and cookies apply, so the page may look different or ask you to sign in."
}

extension SpacesStore {
    /// The profile a row belongs to: a Favorite's own, else its Space's.
    public func profileID(ofItem itemID: String) -> String? {
        guard let i = item(itemID) else { return nil }
        switch i.container {
        case .favorites(let pid): return pid
        case .pinned(let sid): return space(sid)?.profileID
        default: return i.spaceID.flatMap { space($0)?.profileID }
        }
    }

    /// The Move to › targets for rows of `profileID` (see MoveToPlan). `excludingSpace` is the rows' own Space;
    /// `favorites` adds each other profile's Favorites (a Favorite's menu).
    public func moveToPlan(fromProfile profileID: String, excludingSpace: String?, favorites: Bool) -> MoveToPlan {
        let spaces = orderedSpaces.filter { !$0.isBlankWindow }
        func rows(_ pid: String) -> [MoveToPlan.Row] {
            let cross = pid != profileID
            var r: [MoveToPlan.Row] = []
            if favorites, cross { r.append(.init(target: .favorites(profileID: pid), title: "Favorites", crossProfile: true)) }
            for s in spaces where s.profileID == pid && s.id != excludingSpace {
                r.append(.init(target: .space(s.id), title: LinkSpaceMenu.title(of: s), crossProfile: cross))
            }
            return r
        }
        let others = orderedProfiles.filter { p in p.id != profileID && spaces.contains { $0.profileID == p.id } }
        var sections = [MoveToPlan.Section(profileID: profileID, header: nil, rows: rows(profileID))]
        for p in others { sections.append(.init(profileID: p.id, header: p.name, rows: rows(p.id))) }
        sections.removeAll { $0.rows.isEmpty }
        if sections.count == 1 { sections[0].header = nil }
        return MoveToPlan(sections: sections)
    }

    /// The plan for one sidebar row's menu: a Favorite's (Spaces, other profiles' Favorites), a pinned row's or
    /// folder's (other Spaces).
    public func moveToPlan(forItem itemID: String) -> MoveToPlan {
        guard let i = item(itemID), let pid = profileID(ofItem: itemID) else { return MoveToPlan(sections: []) }
        return moveToPlan(fromProfile: pid, excludingSpace: i.isFavorite ? nil : i.spaceID, favorites: i.isFavorite)
    }

    /// Favorite › Move to ›: the Favorites go to the end of `target` — a Space's pinned section (they stop being
    /// Favorites) or another profile's Favorites — in order, as one ⌘Z. A full Favorites grid refuses the lot.
    /// Returns the tabs whose page must reopen in another profile.
    @discardableResult
    public func moveFavorites(_ itemIDs: [String], to target: MoveToPlan.Target) throws -> [String] {
        let favs = itemIDs.filter { item($0)?.isFavorite == true }
        guard !favs.isEmpty else { throw StoreError.notFound }
        let sources = favs.map { DragSource.item($0) }
        switch target {
        case .space(let sid):
            guard space(sid) != nil else { throw StoreError.notFound }
            return try perform("Move to Space", undoable: true) {
                try move(sources, to: .pinned(spaceID: sid, parentID: nil, index: pinnedRoots(ofSpace: sid).count))
            }
        case .favorites(let pid):
            guard profile(pid) != nil else { throw StoreError.notFound }
            let incoming = favs.filter { item($0)?.container != .favorites(profileID: pid) }
            if favorites(ofProfile: pid).count + incoming.count > Self.maxFavorites { throw StoreError.favoritesFull }
            return try perform("Move Favorite", undoable: true) {
                try move(sources, to: .favorites(profileID: pid, index: favorites(ofProfile: pid).count))
            }
        }
    }

    /// Folder › Move to › (and a pinned row's, and a selection's): the rows go to `spaceID` with everything inside them,
    /// nesting intact (`move(_:toSpace:)`), and selected Favorites become pinned there too. One ⌘Z. Returns the tabs
    /// whose page must reopen in the other Space's profile.
    @discardableResult
    public func moveRows(_ sources: [DragSource], toSpace spaceID: String) throws -> [String] {
        guard space(spaceID) != nil else { throw StoreError.notFound }
        let favs = sources.compactMap { s -> String? in
            if case .item(let id) = s, item(id)?.isFavorite == true { return id }
            return nil
        }
        return try perform("Move to Space", undoable: true) {
            var reload = try move(sources, toSpace: spaceID)
            if !favs.isEmpty { reload += try moveFavorites(favs, to: .space(spaceID)) }
            return reload
        }
    }

    /// The live tabs a move to `profileID` would reopen: those of `sources` (folders' nested rows too) in another
    /// profile.
    public func tabsReopening(_ sources: [DragSource], inProfile profileID: String) -> [LiveTab] {
        liveTabs(of: sources).filter { $0.profileID != profileID }
    }
}
