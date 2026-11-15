// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// SP-31: the rows of a page link's "Open Link in Space ›" menu, the same on both engines.
public enum LinkSpaceMenu {
    /// The engine's limit (Chromium's menu takes at most 100 rows).
    public static let limit = 100

    /// `spaces` in sidebar order, each profile's included (a link opens in the chosen Space's profile). A blank window
    /// pages through no other Space, so it lists only its own. Titles lead with the Space's emoji, or "●" without one.
    public static func rows(spaces: [Space], current: Space?) -> [[String: String]] {
        let listed = current?.isBlankWindow == true ? [current!] : spaces.filter { !$0.isBlankWindow }
        return listed.prefix(limit).map { ["id": $0.id, "title": title(of: $0)] }
    }

    public static func title(of space: Space) -> String {
        let icon: String
        if case .emoji(let emoji)? = space.icon, !emoji.isEmpty { icon = emoji } else { icon = "●" }
        return icon + " " + space.name
    }

    /// Only web links open in a Space (the page's other schemes keep their own handling).
    public static func opens(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
