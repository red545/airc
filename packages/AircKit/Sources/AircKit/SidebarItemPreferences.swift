// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// The per-row switches in Arc's tab menus that aren't part of the row itself (S03): "Show Unread Badge" on a Favorite
/// whose site counts unread items in its title (Gmail, Slack, X…; URLRules.showsUnreadBadge), and (S16) "Show Hover
/// Preview" on a pinned tab or Favorite. On until turned off. Kept with the app's settings, so a row's switch stays on
/// this Mac; a deleted row's switch goes with it.
public struct SidebarItemPreferences: Codable, Equatable, Sendable {
    /// Favorites whose unread dot is off.
    public var noUnreadBadge: Set<String> = []
    /// Pinned tabs and Favorites whose hover preview (the page's picture or the site's card) is off.
    public var noHoverPreview: Set<String> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        noUnreadBadge = (try? c.decodeIfPresent(Set<String>.self, forKey: .noUnreadBadge)) ?? []
        noHoverPreview = (try? c.decodeIfPresent(Set<String>.self, forKey: .noHoverPreview)) ?? []
    }

    public func showsUnreadBadge(_ itemID: String) -> Bool { !noUnreadBadge.contains(itemID) }

    /// `existing`: the rows there are, so switches of deleted ones don't stay behind.
    public mutating func setUnreadBadge(_ on: Bool, for itemID: String, existing: Set<String>) {
        if on { noUnreadBadge.remove(itemID) } else { noUnreadBadge.insert(itemID) }
        noUnreadBadge.formIntersection(existing.union([itemID]))
    }

    public func showsHoverPreview(_ itemID: String) -> Bool { !noHoverPreview.contains(itemID) }

    /// `existing`: the rows there are, so switches of deleted ones don't stay behind.
    public mutating func setHoverPreview(_ on: Bool, for itemID: String, existing: Set<String>) {
        if on { noHoverPreview.remove(itemID) } else { noHoverPreview.insert(itemID) }
        noHoverPreview.formIntersection(existing.union([itemID]))
    }
}

extension SpacesStore {
    /// Arc's "Change Icon…" on a tab: a Today tab keeps the emoji itself (it goes with the tab when it's pinned or made a
    /// Favorite, and comes back when it's unpinned); a pinned tab's or Favorite's goes on its item. nil or "": its
    /// favicon again.
    public func setTabIcon(_ tabID: String, to emoji: String?) throws {
        guard var t = tab(tabID) else { throw StoreError.notFound }
        let icon = emoji.flatMap { $0.isEmpty ? nil : $0 }
        if let iid = t.itemID { return try setItemIcon(iid, to: icon) }
        t.icon = icon
        try perform(nil) { put(t) }
    }
}
