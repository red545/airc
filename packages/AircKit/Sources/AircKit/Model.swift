// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// The persistent model (spec §3.4). Every type is a plain value; SpacesStore owns the
// collection and writes every change to SQLite as an operation log.

/// Fresh identifier for any entity.
public func newID() -> String { UUID().uuidString.lowercased() }

// MARK: - Colour and theme

/// An sRGB colour with components in 0...1.
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// "#RRGGBB" or "#RRGGBBAA" (the "#" is optional). Invalid input gives nil.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        } else {
            self.init(Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255,
                      Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
    }

    public var hex: String {
        func c(_ x: Double) -> String { String(format: "%02X", Int((min(max(x, 0), 1) * 255).rounded())) }
        return "#" + c(r) + c(g) + c(b)
    }
}

/// Arc's appearance choice: Auto follows the colour's lightness (Arc ref §4.2).
public enum Appearance: String, Codable, Hashable, Sendable, CaseIterable {
    case auto, light, dark
}

/// A Space's theme (TH-1, TH-2): up to three colours mixed in OKLab on a 45° diagonal.
public struct SpaceTheme: Codable, Hashable, Sendable {
    /// 0–3 colours. Empty means Arc's neutral default theme.
    public var colors: [RGBA]
    /// 0...1. Arc's default is 0.81.
    public var intensity: Double
    /// 0...1 noise strength.
    public var grain: Double
    public var appearance: Appearance

    public init(colors: [RGBA], intensity: Double = SpaceTheme.defaultIntensity, grain: Double = 0,
                appearance: Appearance = .auto) {
        self.colors = Array(colors.prefix(3))
        self.intensity = min(max(intensity, 0), 1)
        self.grain = min(max(grain, 0), 1)
        self.appearance = appearance
    }

    public static let defaultIntensity = 0.81

    /// Arc's nine swatches (Arc ref §4.1), in picker order.
    public static let presets: [(name: String, color: RGBA)] = [
        ("Cream", RGBA(hex: "F0EAE5")!), ("Pink", RGBA(hex: "E59EBA")!), ("Purple", RGBA(hex: "9E749B")!),
        ("Red", RGBA(hex: "E1676F")!), ("Orange", RGBA(hex: "EF8C63")!), ("Yellow", RGBA(hex: "F2D46C")!),
        ("Green", RGBA(hex: "73E49B")!), ("Blue", RGBA(hex: "7EB6D5")!), ("Slate", RGBA(hex: "656786")!),
    ]

    public static func single(_ hex: String, intensity: Double = defaultIntensity) -> SpaceTheme {
        SpaceTheme(colors: [RGBA(hex: hex) ?? RGBA(0.5, 0.5, 0.5)], intensity: intensity)
    }

    /// The neutral theme a fresh install starts with.
    public static let neutral = SpaceTheme(colors: [])
}

/// A Space's icon: an emoji, or an SF Symbol name for Arc's icon tab. nil shows a dot.
public enum SpaceIcon: Codable, Hashable, Sendable {
    case emoji(String)
    case symbol(String)
}

// MARK: - Profiles

/// Auto-archive interval for Today tabs, per profile (SB-43). Arc 1.171's choices.
public enum ArchiveInterval: String, Codable, Hashable, Sendable, CaseIterable {
    case twelveHours, twentyFourHours, sevenDays, thirtyDays

    public var seconds: TimeInterval {
        switch self {
        case .twelveHours: 12 * 3600
        case .twentyFourHours: 24 * 3600
        case .sevenDays: 7 * 86400
        case .thirtyDays: 30 * 86400
        }
    }

    public var label: String {
        switch self {
        case .twelveHours: "12 hours"
        case .twentyFourHours: "24 hours"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }
}

public enum SearchEngine: String, Codable, Hashable, Sendable, CaseIterable {
    case google, duckDuckGo, bing, kagi, ecosia

    public var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        }
    }

    public func searchURL(for query: String) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let base: String = switch self {
        case .google: "https://www.google.com/search?q="
        case .duckDuckGo: "https://duckduckgo.com/?q="
        case .bing: "https://www.bing.com/search?q="
        case .kagi: "https://kagi.com/search?q="
        case .ecosia: "https://www.ecosia.org/search?q="
        }
        return URL(string: base + q)!
    }
}

/// SP-1: a profile is a real browser profile (its own logins, cookies, history) plus our settings.
public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var emoji: String
    public var color: RGBA
    /// The engine's profile folder (Chromium `User Data/<dir>`) or data-store identifier (WebKit).
    /// Fixed at creation; never reused.
    public var engineDirectory: String
    public var archiveAfter: ArchiveInterval
    public var searchEngine: SearchEngine
    /// Signed-in Google account, for display only (SB-22).
    public var googleAccount: String?
    /// SP-12: local, per-profile setup progress; nil for profiles saved by older versions.
    public var googleSignIn: ProfileSignInState?
    /// The one profile that always exists and can't be deleted.
    public var isDefault: Bool
    public var createdAt: Date
    /// Where an import got it from ("arc-profile:Profile 1"), so re-importing updates instead of duplicating.
    public var sourceID: String?

    public init(id: String = newID(), name: String, emoji: String = "", color: RGBA = RGBA(hex: "7EB6D5")!,
                engineDirectory: String? = nil, archiveAfter: ArchiveInterval = .twelveHours,
                searchEngine: SearchEngine = .google, googleAccount: String? = nil, isDefault: Bool = false,
                createdAt: Date = Date(), sourceID: String? = nil) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.color = color
        self.engineDirectory = engineDirectory ?? (isDefault ? "Default" : "Profile-" + id.prefix(8))
        self.archiveAfter = archiveAfter
        self.searchEngine = searchEngine
        self.googleAccount = googleAccount
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.sourceID = sourceID
    }
}

// MARK: - Spaces

/// SP-2: a Space has a name, icon, theme, pinned tree, Today tabs and exactly one profile.
public struct Space: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var icon: SpaceIcon?
    public var theme: SpaceTheme
    public var profileID: String
    /// Position in the Space bar (fractional, so a reorder touches one record).
    public var order: Double
    /// SP-23: each Space reopens on the tab it last showed.
    public var lastActiveTabID: String?
    /// SB-20: pressing the Space name folds the pinned section.
    public var pinnedCollapsed: Bool
    public var createdAt: Date
    /// The imported Space's source ID ("arc-space:<id>"); re-importing updates this Space.
    public var sourceID: String?
    /// WIN-7: the Space of a blank window (⌃⌘N, Arc's "blank windows are separate"): that window's own Today tabs and
    /// pinned items. It's never listed with the others (Space bar, Command Bar, Library, Manage Spaces), and goes when
    /// its window closes (`closeBlankWindowSpace`). nil in every other Space (and in rows from before it).
    public var blankWindow: Bool?

    public var isBlankWindow: Bool { blankWindow == true }

    public init(id: String = newID(), name: String, icon: SpaceIcon? = nil, theme: SpaceTheme = .neutral,
                profileID: String, order: Double = 0, lastActiveTabID: String? = nil,
                pinnedCollapsed: Bool = false, createdAt: Date = Date(), sourceID: String? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.theme = theme
        self.profileID = profileID
        self.order = order
        self.lastActiveTabID = lastActiveTabID
        self.pinnedCollapsed = pinnedCollapsed
        self.createdAt = createdAt
        self.sourceID = sourceID
    }
}

// MARK: - Sidebar items (pinned tabs, folders, Favorites)

public enum ItemKind: String, Codable, Hashable, Sendable {
    case tab, folder
    /// SV-2: a pinned or Favorite split. Its panes are its child items (tabs), in order (ItemSplits.swift). A build
    /// without this case can't read the row and hides it with its panes, keeping them on disk (H4).
    case split
}

/// Where an item lives: in a Space's pinned tree, or in a profile's Favorites (SB-10).
public enum ItemContainer: Codable, Hashable, Sendable {
    case pinned(spaceID: String)
    case favorites(profileID: String)
}

/// A persistent sidebar row that exists without a loaded page (SB-30).
public struct Item: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ItemKind
    public var container: ItemContainer
    /// Folder that holds this item, if any (pinned items only).
    public var parentID: String?
    /// Position among its siblings.
    public var order: Double
    /// The saved URL a pinned tab or Favorite snaps back to (SB-12, SB-31). nil for folders.
    public var savedURL: String?
    /// The user's custom name. nil means "use the page title". Folders always have one.
    public var title: String?
    /// Last page title seen for this item.
    public var pageTitle: String?
    public var faviconURL: String?
    /// Custom icon (emoji), SB-33 / Arc "Change Icon".
    public var icon: String?
    public var isCollapsed: Bool
    public var createdAt: Date
    /// The imported item's source ID ("arc-item:<id>"); re-importing updates instead of duplicating.
    public var sourceID: String?
    /// SV-2: a split's layout (axis, the panes' shares, the focused pane). nil for tabs and folders; older rows have
    /// none.
    public var splitLayout: SplitLayout?

    public init(id: String = newID(), kind: ItemKind, container: ItemContainer, parentID: String? = nil,
                order: Double = 0, savedURL: String? = nil, title: String? = nil, pageTitle: String? = nil,
                faviconURL: String? = nil, icon: String? = nil, isCollapsed: Bool = false,
                createdAt: Date = Date(), sourceID: String? = nil, splitLayout: SplitLayout? = nil) {
        self.id = id
        self.kind = kind
        self.container = container
        self.parentID = parentID
        self.order = order
        self.savedURL = savedURL
        self.title = title
        self.pageTitle = pageTitle
        self.faviconURL = faviconURL
        self.icon = icon
        self.isCollapsed = isCollapsed
        self.createdAt = createdAt
        self.sourceID = sourceID
        self.splitLayout = splitLayout
    }

    public var isFavorite: Bool {
        if case .favorites = container { return true }
        return false
    }

    public var spaceID: String? {
        if case .pinned(let id) = container { return id }
        return nil
    }

    public var profileID: String? {
        if case .favorites(let id) = container { return id }
        return nil
    }

    /// What the sidebar shows: custom name, then page title, then the URL's host.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let pageTitle, !pageTitle.isEmpty { return pageTitle }
        if let savedURL { return URLRules.displayHost(savedURL) }
        return "Untitled"
    }
}

// MARK: - Live tabs and archive

/// A tab: a Today tab, or the live page of a pinned item or Favorite. Persisted so Today
/// survives restarts (SP-4); the engine page itself is created lazily.
public struct LiveTab: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The profile the page loads in. Always the Space's profile, or the Favorite's profile.
    public var profileID: String
    /// The Space it belongs to. nil for a Favorite's tab, which every Space of the profile shares.
    public var spaceID: String?
    /// The pinned item or Favorite this tab is the live page of. nil = a Today tab.
    public var itemID: String?
    public var url: String
    public var title: String
    public var faviconURL: String?
    /// Today order: smaller is higher. New tabs go to the top (SB-42).
    public var order: Double
    public var openerID: String?
    public var isMuted: Bool
    public var createdAt: Date
    /// Viewing a tab resets its archive timer (SB-43).
    public var lastActiveAt: Date
    /// An imported Today tab's source ID ("arc-item:<id>").
    public var sourceID: String?
    /// A Today tab's own icon (an emoji, Arc's "Change Icon…" on a Today tab); a pinned tab's is its item's. Older files
    /// have none, and a tab without one encodes as before.
    public var icon: String?

    public init(id: String = newID(), profileID: String, spaceID: String?, itemID: String? = nil, url: String,
                title: String = "", faviconURL: String? = nil, order: Double = 0, openerID: String? = nil,
                isMuted: Bool = false, createdAt: Date = Date(), lastActiveAt: Date? = nil, sourceID: String? = nil) {
        self.id = id
        self.profileID = profileID
        self.spaceID = spaceID
        self.itemID = itemID
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.order = order
        self.openerID = openerID
        self.isMuted = isMuted
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt ?? createdAt
        self.sourceID = sourceID
    }

    public var isToday: Bool { itemID == nil }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if URLRules.isNewTab(url) { return "New Tab" }
        return URLRules.displayHost(url)
    }
}

public enum ArchiveReason: String, Codable, Hashable, Sendable {
    case auto, manual, clear, spaceDeleted
}

/// A closed Today tab, restorable from the Library (SB-62).
public struct ArchiveEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var faviconURL: String?
    public var spaceID: String?
    public var profileID: String
    public var archivedAt: Date
    public var reason: ArchiveReason
    /// Where the tab was besides its Space (P10a): `littleArcOrigin` for a Little Arc page. Older files have none.
    public var origin: String?
    /// The tab as it was, so a restore puts it back exactly.
    public var tab: LiveTab

    /// `origin` of a page archived from Little Arc (the Library's "Where was the tab?" filter).
    public static let littleArcOrigin = "littleArc"

    public init(tab: LiveTab, reason: ArchiveReason, at date: Date) {
        id = newID()
        url = tab.url
        title = tab.title
        faviconURL = tab.faviconURL
        spaceID = tab.spaceID
        profileID = tab.profileID
        archivedAt = date
        self.reason = reason
        self.tab = tab
    }
}

/// Per-window state that survives relaunch.
public struct WindowState: Codable, Hashable, Sendable {
    public var selectedSpaceID: String?
    public var sidebarWidth: Double
    public var sidebarHidden: Bool
    public var sidebarOnRight: Bool
    public var frame: [Double]?

    public init(selectedSpaceID: String? = nil, sidebarWidth: Double = 228, sidebarHidden: Bool = false,
                sidebarOnRight: Bool = false, frame: [Double]? = nil) {
        self.selectedSpaceID = selectedSpaceID
        self.sidebarWidth = sidebarWidth
        self.sidebarHidden = sidebarHidden
        self.sidebarOnRight = sidebarOnRight
        self.frame = frame
    }
}

// MARK: - Forward compatibility (code review H4)

// A value a newer Airc wrote (a new search engine, archive interval, appearance or icon kind) reads as the default
// here instead of making the whole row unreadable. The store keeps the stored value on disk unless this build changes
// that field. New fields must be optional or decoded with a default, so an older row still reads.

extension SearchEngine {
    public init(from decoder: Decoder) throws {
        self = SearchEngine(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .google
    }
}

extension ArchiveInterval {
    public init(from decoder: Decoder) throws {
        self = ArchiveInterval(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .twelveHours
    }
}

extension Appearance {
    public init(from decoder: Decoder) throws {
        self = Appearance(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .auto
    }
}

extension ArchiveReason {
    public init(from decoder: Decoder) throws {
        self = ArchiveReason(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .manual
    }
}

extension SpaceIcon {
    private enum Case: String, CodingKey { case emoji, symbol }
    private enum Payload: String, CodingKey { case value = "_0" }

    /// The icon shown for an icon kind this build doesn't know.
    public static let unknown = SpaceIcon.symbol("circle.dashed")

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Case.self)
        func payload(_ k: Case) -> String? {
            try? c.nestedContainer(keyedBy: Payload.self, forKey: k).decode(String.self, forKey: .value)
        }
        if let e = payload(.emoji) { self = .emoji(e) }
        else if let s = payload(.symbol) { self = .symbol(s) }
        else { self = .unknown }
    }
}
