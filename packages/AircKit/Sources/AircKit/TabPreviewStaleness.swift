// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// S16: what a tab preview card says about a kept picture (Sidebar/TabPreviewCard.swift). A page on screen is pictured
/// live and says nothing. A kept picture says how old it is once that matters: always when the page isn't loaded (it
/// was unloaded to save memory, or a Favorite or pinned tab has no tab open), otherwise once it's older than
/// `quietFor`, because the page may have changed since.
public enum TabPreviewStaleness {
    /// A kept picture of a loaded page younger than this carries no hint.
    public static let quietFor: TimeInterval = 60

    /// The hint for a picture `age` seconds old, or nil for none. `loaded`: the tab's page is in memory.
    public static func hint(age: TimeInterval, loaded: Bool) -> String? {
        if loaded, age < quietFor { return nil }
        let when = ago(age)
        return loaded ? "Pictured \(when)" : "Not loaded · pictured \(when)"
    }

    /// "just now", "1 min ago", "12 min ago", "3 hr ago", "2 days ago".
    public static func ago(_ age: TimeInterval) -> String {
        let s = max(0, age)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) hr ago" }
        let d = Int(s / 86400)
        return d == 1 ? "1 day ago" : "\(d) days ago"
    }
}
