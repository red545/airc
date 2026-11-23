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

/// Arc's background texture (`modifiers.overlay`, TH-4): grain, sand, denim or tweed, drawn at `SpaceTheme.grain`.
///
/// A struct over its stored string, not an enum (archivenever's lesson): themes sync between Macs and live in backups,
/// so a build must read a texture a newer Airc wrote, draw it as grain (`effective`), and keep and send back that exact
/// string, never its fallback. Never rename a raw value.
public struct SpaceTexture: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let grain = SpaceTexture(rawValue: "grain")
    public static let sand = SpaceTexture(rawValue: "sand")
    public static let denim = SpaceTexture(rawValue: "denim")
    public static let tweed = SpaceTexture(rawValue: "tweed")

    /// Every texture this build draws, in the picker's order (Arc's).
    public static let allCases: [SpaceTexture] = [.grain, .sand, .denim, .tweed]

    /// Whether this build knows the texture.
    public var isKnown: Bool { Self.allCases.contains(self) }
    /// What this build draws: the texture, or grain for one a newer Airc set.
    public var effective: SpaceTexture { isKnown ? self : .grain }

    /// A string decodes as itself, known or not; anything else (a newer build's richer value) reads as grain.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        rawValue = (try? c.decode(String.self)) ?? Self.grain.rawValue
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// A Space's theme (TH-1, TH-2): up to three colours mixed in OKLab on a 45° diagonal.
public struct SpaceTheme: Codable, Hashable, Sendable {
    /// 0–3 colours. Empty means Arc's neutral default theme.
    public var colors: [RGBA]
    /// 0...1. Arc's default is 0.81.
    public var intensity: Double
    /// 0...1 noise strength (Arc's `noiseFactor`): how strongly `texture` shows.
    public var grain: Double
    /// Arc's texture (TH-4). Grain unless the Space chose (or imported) another.
    public var texture: SpaceTexture
    public var appearance: Appearance

    public init(colors: [RGBA], intensity: Double = SpaceTheme.defaultIntensity, grain: Double = 0,
                texture: SpaceTexture = .grain, appearance: Appearance = .auto) {
        self.colors = Array(colors.prefix(3))
        self.intensity = min(max(intensity, 0), 1)
        self.grain = min(max(grain, 0), 1)
        self.texture = texture
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey { case colors, intensity, grain, texture, appearance }

    /// arctextures: `texture` is optional on disk and over sync. Rows and backups from before it read as grain; an
    /// unreadable value reads as grain instead of failing the Space. The other keys decode exactly as before.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colors = try c.decode([RGBA].self, forKey: .colors)
        intensity = try c.decode(Double.self, forKey: .intensity)
        grain = try c.decode(Double.self, forKey: .grain)
        texture = (try? c.decodeIfPresent(SpaceTexture.self, forKey: .texture)) ?? .grain
        appearance = try c.decode(Appearance.self, forKey: .appearance)
    }

    /// Grain is left out, so a grain theme encodes byte for byte as it did before textures existed.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(colors, forKey: .colors)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(grain, forKey: .grain)
        if texture != .grain { try c.encode(texture, forKey: .texture) }
        try c.encode(appearance, forKey: .appearance)
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
///
/// A struct over its stored string rather than an enum (archivenever, 2026-11-21): the value syncs between Macs
/// ("profile.archiveAfter@…", Settings sync), so a build must read an interval a newer Airc wrote without failing the
/// profile row, act on it as the default (`effective`), and keep and send back that exact string, never its fallback.
/// The enum before it read an unknown value as 12 hours and then wrote "twelveHours" back over sync, which replaced the
/// newer Mac's choice. Never rename a raw value.
public struct ArchiveInterval: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let twelveHours = ArchiveInterval(rawValue: "twelveHours")
    public static let twentyFourHours = ArchiveInterval(rawValue: "twentyFourHours")
    public static let sevenDays = ArchiveInterval(rawValue: "sevenDays")
    public static let thirtyDays = ArchiveInterval(rawValue: "thirtyDays")
    /// Arc's other choices (archivenever): known to every build from the one that added them, offered in the pickers
    /// only with `moreChoicesOffered`. "Never": Today tabs never auto-archive (Clear still clears them).
    public static let oneHour = ArchiveInterval(rawValue: "oneHour")
    public static let sixHours = ArchiveInterval(rawValue: "sixHours")
    public static let never = ArchiveInterval(rawValue: "never")

    /// What a profile starts with, and what an interval this build doesn't know acts as.
    public static let `default` = twelveHours

    /// Every interval this build understands, in the pickers' order.
    public static let known: [ArchiveInterval] = [.oneHour, .sixHours, .twelveHours, .twentyFourHours, .sevenDays, .thirtyDays, .never]

    /// What the pickers offered before `moreChoicesOffered`.
    public static let original: [ArchiveInterval] = [.twelveHours, .twentyFourHours, .sevenDays, .thirtyDays]

    /// Whether the pickers offer 1 hour, 6 hours and Never. Off until every build people may still sync with keeps an
    /// interval it doesn't know (the build that made ArchiveInterval keep its raw value, 0.1.48): up to 0.1.47 a Mac that
    /// receives "never" sends "twelveHours" back and replaces it everywhere (docs/sync.md, Settings). The release after
    /// the one that ships this turns `moreChoicesByDefault` on; until then `defaults write <bundle id>
    /// AircArchiveMoreChoices -bool YES` (or a test's `moreChoicesOverride`) shows them. Every build since knows and
    /// honours the three values either way: only offering them waits.
    public static let moreChoicesByDefault = true
    public static let moreChoicesDefaultsKey = "AircArchiveMoreChoices"
    nonisolated(unsafe) public static var moreChoicesOverride: Bool?
    public static var moreChoicesOffered: Bool {
        moreChoicesOverride ?? (UserDefaults.standard.object(forKey: moreChoicesDefaultsKey) as? Bool ?? moreChoicesByDefault)
    }

    /// The pickers' choices (Settings › Profiles, the tidy card).
    public static var allCases: [ArchiveInterval] { moreChoicesOffered ? known : original }

    /// The choices to show while `current` is selected: `allCases`, plus `current` at the end when it isn't one of them
    /// (an interval a newer Airc set), so the picker shows what's set instead of a wrong choice.
    public static func choices(current: ArchiveInterval) -> [ArchiveInterval] {
        allCases.contains(current) ? allCases : allCases + [current]
    }

    /// Whether this build knows the value (a newer Airc may have written another).
    public var isKnown: Bool { Self.known.contains(self) }

    /// What this build does with it: an unknown interval acts as the default, and keeps its own value on disk and in sync.
    public var effective: ArchiveInterval { isKnown ? self : .default }

    /// Whether Today tabs of the profile auto-archive at all (not with Never).
    public var archives: Bool { effective != .never }

    /// How long a Today tab stays without being looked at; `.infinity` for Never.
    public var seconds: TimeInterval {
        switch effective {
        case .oneHour: 3600
        case .sixHours: 6 * 3600
        case .never: .infinity
        case .twentyFourHours: 24 * 3600
        case .sevenDays: 7 * 86400
        case .thirtyDays: 30 * 86400
        default: 12 * 3600
        }
    }

    public var label: String {
        switch self {
        case .oneHour: "1 hour"
        case .sixHours: "6 hours"
        case .never: "Never"
        case .twelveHours: "12 hours"
        case .twentyFourHours: "24 hours"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        default: "Set by a newer Airc"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Never throws for a string; a non-string (a damaged row) reads as the default rather than failing the profile.
        self = (try? c.decode(String.self)).map(ArchiveInterval.init(rawValue:)) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// A profile's built-in search engine (Settings → Profiles → Search engine; Arc's "Default Search Engine"). Arc listed
/// its Chromium's prepopulated engines; these are Chromium 156's choices across regions (Google, DuckDuckGo, Brave,
/// Bing, Ecosia; Yahoo, Startpage and Perplexity in some) plus Kagi. Declared in the picker's order; the raw values are
/// what's stored, so never rename one. An older build reads a newer engine as Google (`init(from:)` below).
public enum SearchEngine: String, Codable, Hashable, Sendable, CaseIterable {
    case google, bing, duckDuckGo, ecosia, brave, yahoo, startpage, perplexity, kagi

    public var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        case .brave: "Brave"
        case .yahoo: "Yahoo"
        case .startpage: "Startpage"
        case .perplexity: "Perplexity"
        }
    }

    /// The results page's address up to the query (Chromium's prepopulated search_url, its tracking parameters left out).
    var searchBase: String {
        switch self {
        case .google: "https://www.google.com/search?q="
        case .duckDuckGo: "https://duckduckgo.com/?q="
        case .bing: "https://www.bing.com/search?q="
        case .kagi: "https://kagi.com/search?q="
        case .ecosia: "https://www.ecosia.org/search?q="
        case .brave: "https://search.brave.com/search?q="
        case .yahoo: "https://search.yahoo.com/search?p="
        case .startpage: "https://www.startpage.com/sp/search?q="
        case .perplexity: "https://www.perplexity.ai/search?q="
        }
    }

    /// The suggestion endpoint up to the query (Chromium's prepopulated suggest_url; every one answers with OpenSearch
    /// suggestions JSON, `["query", ["s1", …]]`).
    var suggestBase: String {
        switch self {
        case .google: "https://suggestqueries.google.com/complete/search?client=firefox&q="
        case .duckDuckGo: "https://duckduckgo.com/ac/?type=list&q="
        case .bing: "https://api.bing.com/osjson.aspx?query="
        case .ecosia: "https://ac.ecosia.org/autocomplete?type=list&q="
        case .kagi: "https://kagisuggest.com/api/autosuggest?q="
        case .brave: "https://search.brave.com/api/suggest?q="
        case .yahoo: "https://search.yahoo.com/sugg/chrome?output=fxjson&appid=crmas_sfp&command="
        case .startpage: "https://www.startpage.com/osuggestions?q="
        case .perplexity: "https://suggest.perplexity.ai/suggest?q="
        }
    }

    /// The query as a URL query value.
    static func encode(_ query: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
    }

    public func searchURL(for query: String) -> URL {
        URL(string: SearchEngineStandIn.route(searchBase) + Self.encode(query))!
    }
}

/// Test builds' loopback stand-in for every engine (C08): set, every engine's search and suggestion addresses go to
/// `origin` + "/" + the engine's host + its path, so a check sees which engine was asked and nothing leaves the Mac.
/// Only test code sets it (the app's `AIRC_TESTING` checks).
public enum SearchEngineStandIn {
    nonisolated(unsafe) public static var origin: String?

    public static func route(_ base: String) -> String {
        guard let origin, let r = base.range(of: "://") else { return base }
        return origin + "/" + base[r.upperBound...]
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
    /// Arc's per-profile "Include search engine suggestions" (C08): nil (never changed) is on. The app-wide switch
    /// (Settings → Privacy) still turns every profile's off.
    public var searchSuggestions: Bool?
    /// Signed-in Google account, for display only (SB-22).
    public var googleAccount: String?
    /// That account's name and picture address, from Google's ListAccounts answer (SB-22). Local only, like the email.
    public var googleAccountName: String?
    public var googleAccountPhoto: String?
    /// Where that account sits in the profile's Google sign-ins: 0 for u/0, 1 for u/1 (the `authuser` index).
    public var googleAccountIndex: Int?
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

extension Profile {
    /// Whether the Command Bar asks this profile's search engine for suggestions (Arc's per-profile switch, on by default).
    public var includesSearchSuggestions: Bool { searchSuggestions ?? true }
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
    /// A folder in a Space's Today list (Arc's unpinned folders, TodayFolders.swift): only `kind == .folder`. Its tabs
    /// are Today tabs with `LiveTab.folderID`; a Today folder can hold Today folders (`parentID`), as in Arc. Schema 3: a
    /// build before it can't read the row and hides it, keeping it on disk (H4), and shows its tabs loose in Today.
    case today(spaceID: String)
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

    /// The Space a pinned item or Today folder is in.
    public var spaceID: String? {
        switch container {
        case .pinned(let id), .today(let id): id
        case .favorites: nil
        }
    }

    /// A folder in a Space's Today list (TodayFolders.swift).
    public var isTodayFolder: Bool {
        if case .today = container { return true }
        return false
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
    /// The Today folder (an `Item` in `.today(spaceID:)`) this Today tab is in; nil = loose in Today. Only on a Today
    /// tab of that folder's Space (`repair` and `tidyTodayFolders` clear it otherwise). Encoded only when set, so a tab
    /// outside a folder reads and writes as before; an older build keeps it on disk (H4 merge) and shows the tab loose.
    public var folderID: String?

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

// A value a newer Airc wrote (a new search engine, appearance or icon kind) reads as the default here instead of making
// the whole row unreadable; an archive interval also keeps its own value (ArchiveInterval above). The store keeps the
// stored value on disk unless this build changes that field. New fields must be optional or decoded with a default, so
// an older row still reads.

extension SearchEngine {
    public init(from decoder: Decoder) throws {
        self = SearchEngine(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .google
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
