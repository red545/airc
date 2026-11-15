// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// "What's new" after an update (the app's Updates/WhatsNewCard.swift draws it): each release's highlights, written
// once per release into the app's bundled WhatsNew.json by scripts/release/whatsnew.py from the notes' "New since"
// section, and the same highlights in the update's appcast item (`<airc:highlights>`), so the Restart to Update card
// can say what's coming before the restart. Everything here is pure: the app reads the files and draws.

/// One line of a release: a short title for the card (at most 26 characters: one line in the default sidebar, two at
/// its narrowest), the notes' lead-in, the What's new page's explanation, what its "Show me" button does, an optional
/// bundled picture, and its SF Symbol.
public struct WhatsNewHighlight: Codable, Equatable, Sendable {
    /// What the card shows ("Spaces saved on quit").
    public var title: String
    /// whatsnew2: one or two plain sentences for someone who has never heard of the feature: what it does, why it
    /// helps, where to find it (the What's new tab). Before whatsnew2 this held the notes' lead-in; feeds and files of
    /// then still read (`lead` is nil there, so VoiceOver reads the title).
    public var detail: String?
    /// The notes' bold lead-in ("Your Spaces are saved as soon as you quit"): VoiceOver and the card's tooltip.
    public var lead: String?
    /// An SF Symbol name ("sparkles" when the release names none).
    public var icon: String
    /// The changelog anchor this line opens, if not the release's own ("v0.1.12").
    public var anchor: String?
    /// The "Show me" button's action, by name (WhatsNewAction). A name this build doesn't know shows no button.
    public var actionName: String?
    /// A bundled picture's name, without extension (Contents/Resources/WhatsNew/<image>.heic).
    public var image: String?

    enum CodingKeys: String, CodingKey { case title, detail, lead, icon, anchor, actionName = "action", image }

    /// The fuller text, for VoiceOver and the tooltip.
    public var spoken: String { lead ?? title }
    /// The page's "Show me" action, if this build knows it.
    public var action: WhatsNewAction? { actionName.flatMap(WhatsNewAction.init(rawValue:)) }

    public init(title: String, icon: String, detail: String? = nil, lead: String? = nil, anchor: String? = nil,
                action: WhatsNewAction? = nil, image: String? = nil) {
        self.title = title
        self.detail = detail
        self.lead = lead
        self.icon = icon
        self.anchor = anchor
        actionName = action?.rawValue
        self.image = image
    }
}

/// whatsnew2: what a highlight's "Show me" / "Try it" button may do. A closed list of safe in-app actions: each only
/// opens something the person then uses themselves (a Settings page, the Command Bar, the Library, Send Feedback);
/// none changes a setting or loads a page. The app's WhatsNewPage.swift performs them.
public enum WhatsNewAction: String, Codable, CaseIterable, Sendable {
    case commandBar             // ⌘T, with a hint toast
    case settingsAppIcon        // Settings › Appearance › App Icon
    case settingsSitePreviews   // Settings › Appearance › Site Previews
    case settingsAgents         // Settings › Agents
    case settingsSync           // Settings › Sync
    case settingsImport         // Settings › Import
    case settingsBoosts         // Settings › Boosts
    case settingsGeneral        // Settings › General
    case settingsUpdates        // Settings › General › Automatic Updates
    case libraryArchive         // the Library on Archived Tabs
    case libraryNotes           // the Library on Notes
    case sendFeedback           // Send Feedback…
    case settingsAI             // Settings › AI, scrolled to Downloads (Tidy Downloads)
    case settingsShortcuts      // Settings › Shortcuts

    /// The button's words: "Try it" for something to use right away, "Show me" for where a setting lives.
    public var buttonTitle: String {
        switch self {
        case .commandBar, .sendFeedback: "Try it"
        case .settingsSitePreviews: "Site Previews settings"
        default: "Show me"
        }
    }

    /// Where it leads, for the page's "where to find it" line and VoiceOver ("Settings › Appearance › App Icon").
    public var place: String {
        switch self {
        case .commandBar: "⌘T, or + New Tab in the sidebar"
        case .settingsAppIcon: "Settings › Appearance › App Icon"
        case .settingsSitePreviews: "Settings › Appearance › Site Previews"
        case .settingsAgents: "Settings › Agents"
        case .settingsSync: "Settings › Sync"
        case .settingsImport: "Settings › Import"
        case .settingsBoosts: "Settings › Boosts"
        case .settingsGeneral: "Settings › General"
        case .settingsUpdates: "Settings › General › Automatic Updates"
        case .libraryArchive: "Library › Archived Tabs"
        case .libraryNotes: "Library › Notes"
        case .sendFeedback: "The speech bubble at the bottom of the sidebar"
        case .settingsAI: "Settings › AI › Downloads"
        case .settingsShortcuts: "Settings › Shortcuts"
        }
    }
}

/// whatsnew2: what happens after an update (Settings › General › Automatic Updates › "After an update").
public enum WhatsNewStyle: String, Codable, CaseIterable, Sendable {
    /// Open a "What's new in Airc" tab in the front window, once (the default).
    case tab
    /// The sidebar's small card, for three launches; it opens the tab.
    case card
    /// Nothing (the "Updated!" toast, as before What's new).
    case off
}

/// The What's new tab's address: `airc://whats-new?from=0.1.13&to=0.1.15`. Its tab has no engine page: the app puts
/// the native page in the card (as a note's), so it works offline and looks the same on both engines.
public enum WhatsNewURL {
    public static let prefix = "airc://whats-new"
    public static let title = "What’s New in Airc"

    public static func make(from: String, to: String) -> String { "\(prefix)?from=\(from)&to=\(to)" }

    public static func isPage(_ url: String?) -> Bool {
        guard let url else { return false }
        return url == prefix || url.hasPrefix(prefix + "?") || url.hasPrefix(prefix + "/")
    }

    /// The range an address shows; nil for another address (or none named: the caller shows the newest release).
    public static func range(_ url: String?) -> (from: String, to: String)? {
        guard isPage(url), let url, let c = URLComponents(string: url),
              let from = c.queryItems?.first(where: { $0.name == "from" })?.value, WhatsNewVersion(from) != nil,
              let to = c.queryItems?.first(where: { $0.name == "to" })?.value, WhatsNewVersion(to) != nil else { return nil }
        return (from, to)
    }
}

/// One release's highlights.
public struct WhatsNewRelease: Codable, Equatable, Sendable {
    public var version: String
    public var highlights: [WhatsNewHighlight]

    public init(version: String, highlights: [WhatsNewHighlight]) {
        self.version = version
        self.highlights = highlights
    }
}

/// WhatsNew.json: `{"schema": 1, "releases": [{"version": "0.1.12", "highlights": [{"title", "icon", "anchor"?}]}]}`.
public struct WhatsNewCatalog: Codable, Equatable, Sendable {
    public static let schema = 1
    /// Highlights a release may carry (the generator keeps at most this many). wnactions: 7 (was 5); the tab shows
    /// them all, the sidebar card still shows at most WhatsNewContent.maxLines and "and more".
    public static let maxPerRelease = 7
    /// A card title's length (scripts/release/whatsnew.py fails above it).
    public static let titleMax = 26
    /// A lead-in's length.
    public static let leadMax = 120
    /// The page's explanation: one or two sentences (scripts/release/whatsnew.py fails above it, or without one).
    public static let detailMax = 280
    public var schema: Int
    public var releases: [WhatsNewRelease]

    public init(releases: [WhatsNewRelease]) {
        schema = Self.schema
        self.releases = releases
    }

    public enum Invalid: Error, Equatable {
        case schema(Int)
        case version(String)
        case duplicate(String)
        case empty(String)
        case title(String)
        case icon(String)
        case tooMany(String)
        case detail(String)
        case action(String)
        case image(String)
    }

    /// Decodes and validates the file; nil-free: a bad file throws (the app then shows no card).
    public static func decode(_ data: Data) throws -> WhatsNewCatalog {
        let c = try JSONDecoder().decode(WhatsNewCatalog.self, from: data)
        try c.validate()
        return c
    }

    /// The schema the release script writes and the tests pin: known schema, x.y.z versions once each, 1–7 highlights
    /// per release, one-line titles of at most 26 characters (lead-ins at most 120, details at most 280, one line
    /// each), SF Symbol-shaped icon names, actions from WhatsNewAction only, kebab-case image names.
    public func validate() throws {
        guard schema == Self.schema else { throw Invalid.schema(schema) }
        var seen = Set<String>()
        for r in releases {
            guard WhatsNewVersion(r.version) != nil else { throw Invalid.version(r.version) }
            guard seen.insert(r.version).inserted else { throw Invalid.duplicate(r.version) }
            guard !r.highlights.isEmpty else { throw Invalid.empty(r.version) }
            guard r.highlights.count <= Self.maxPerRelease else { throw Invalid.tooMany(r.version) }
            for h in r.highlights {
                let t = h.title
                guard !t.trimmingCharacters(in: .whitespaces).isEmpty, t.count <= Self.titleMax, !t.contains("\n") else { throw Invalid.title(t) }
                if let l = h.lead, l.trimmingCharacters(in: .whitespaces).isEmpty || l.count > Self.leadMax || l.contains("\n") {
                    throw Invalid.title(l)
                }
                if let d = h.detail, d.trimmingCharacters(in: .whitespaces).isEmpty || d.count > Self.detailMax || d.contains("\n") {
                    throw Invalid.detail(d)
                }
                if let a = h.actionName, WhatsNewAction(rawValue: a) == nil { throw Invalid.action(a) }
                if let i = h.image, i.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) == nil { throw Invalid.image(i) }
                guard h.icon.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)*$"#, options: .regularExpression) != nil else { throw Invalid.icon(h.icon) }
            }
        }
    }

    public func release(_ version: String) -> WhatsNewRelease? { releases.first { $0.version == version } }
}

/// "0.1.12" (or the short part of LastVersion's "0.1.12 (202611131000)"), compared number by number.
public struct WhatsNewVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let description: String

    public init?(_ text: String) {
        let short = text.split(separator: " ").first.map(String.init) ?? ""
        let nums = short.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard nums.count >= 2, nums.count <= 4, nums.allSatisfy({ $0 != nil }) else { return nil }
        parts = nums.map { $0! }
        description = short
    }

    public static func < (a: Self, b: Self) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Self, b: Self) -> Bool { !(a < b) && !(b < a) }
    public func hash(into h: inout Hasher) {
        var p = parts
        while p.last == 0 { p.removeLast() }
        h.combine(p)
    }
}

/// What the card shows: the newest version's name, up to five lines from the versions since the last one seen
/// (newest first), and whether more were left out.
public struct WhatsNewContent: Equatable, Sendable {
    public static let maxLines = 5
    public var version: String
    public var lines: [WhatsNewHighlight]
    /// Lines were left out (more than five across the versions): the card says "and more".
    public var more: Bool
    /// The versions whose highlights it merges, newest first.
    public var versions: [String]

    public init(version: String, lines: [WhatsNewHighlight], more: Bool, versions: [String]) {
        self.version = version
        self.lines = lines
        self.more = more
        self.versions = versions
    }

    /// The changelog address See all opens: the running version's anchor.
    public func changelogURL(base: URL) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.fragment = "v\(version)"
        return c.url!
    }

    /// The releases after `from` up to and including `current`, newest first, merged into at most five lines; nil when
    /// none of them has highlights (an older feed, a dev build).
    public static func merge(_ catalog: WhatsNewCatalog, from: String, current: String,
                             maxLines: Int = WhatsNewContent.maxLines) -> WhatsNewContent? {
        guard let lo = WhatsNewVersion(from), let hi = WhatsNewVersion(current), lo < hi else { return nil }
        let picked = catalog.releases
            .compactMap { r in WhatsNewVersion(r.version).map { (v: $0, r: r) } }
            .filter { lo < $0.v && $0.v <= hi }
            .sorted { $0.v > $1.v }
        let all = picked.flatMap { p in
            p.r.highlights.map { h in
                var h = h
                if h.anchor == nil, p.r.version != hi.description { h.anchor = "v\(p.r.version)" }
                return h
            }
        }
        guard !all.isEmpty else { return nil }
        // The same line in two versions (a fix that shipped twice) shows once, at its newest place.
        var titles = Set<String>(), lines: [WhatsNewHighlight] = []
        for h in all where titles.insert(h.title.lowercased()).inserted { lines.append(h) }
        let cut = Array(lines.prefix(maxLines))
        return WhatsNewContent(version: hi.description, lines: cut, more: lines.count > cut.count,
                               versions: picked.map(\.r.version))
    }
}

/// whatsnew2: the What's new tab's content: every highlight of the releases after `from` up to `current`, grouped by
/// release, newest first; a line that two releases carry shows once, in the newer one.
public struct WhatsNewPageContent: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var version: String
        public var highlights: [WhatsNewHighlight]
    }
    public var version: String
    public var from: String?
    public var sections: [Section]

    /// The range's releases; nil when none has highlights. `from` nil: only `current`'s own release.
    public static func make(_ catalog: WhatsNewCatalog, from: String?, current: String) -> WhatsNewPageContent? {
        guard let hi = WhatsNewVersion(current) else { return nil }
        let lo = from.flatMap(WhatsNewVersion.init)
        func included(_ v: WhatsNewVersion) -> Bool {
            guard v <= hi else { return false }
            if let lo { return lo < v }
            return v == hi
        }
        var picked: [(v: WhatsNewVersion, r: WhatsNewRelease)] = []
        for r in catalog.releases {
            if let v = WhatsNewVersion(r.version), included(v) { picked.append((v, r)) }
        }
        picked.sort { $0.v > $1.v }
        var titles = Set<String>(), sections: [Section] = []
        for p in picked {
            let hs = p.r.highlights.filter { titles.insert($0.title.lowercased()).inserted }
            if !hs.isEmpty { sections.append(Section(version: p.r.version, highlights: hs)) }
        }
        guard !sections.isEmpty else { return nil }
        return WhatsNewPageContent(version: hi.description, from: lo?.description, sections: sections)
    }

    /// The newest release in the catalog at or below `current` (the page with no range named).
    public static func latest(_ catalog: WhatsNewCatalog, current: String) -> WhatsNewPageContent? {
        guard let hi = WhatsNewVersion(current) else { return nil }
        let newest = catalog.releases.compactMap { WhatsNewVersion($0.version) }.filter { $0 <= hi }.max()
        return newest.flatMap { make(catalog, from: nil, current: $0.description) }
    }
}

/// The card's memory, in the data folder (WhatsNewState.json): which version it's for, since which version, how many
/// launches it has been up, whether it was dismissed, and every version it has been offered for (never twice).
public struct WhatsNewState: Codable, Equatable, Sendable {
    /// Launches the card stays for, unless dismissed.
    public static let launches = 3
    public var version: String?
    public var from: String?
    public var shownLaunches = 0
    public var dismissed = false
    public var offered: [String] = []

    public init(version: String? = nil, from: String? = nil, shownLaunches: Int = 0, dismissed: Bool = false, offered: [String] = []) {
        self.version = version
        self.from = from
        self.shownLaunches = shownLaunches
        self.dismissed = dismissed
        self.offered = offered
    }

    /// A card still up (shown fewer than three launches and not dismissed).
    public var pending: Bool { version != nil && !dismissed && shownLaunches < Self.launches }

    /// One launch. `previous` is the version this data folder ran last (nil: a fresh install, which has onboarding
    /// and never gets the card); `current` the running one. Returns the state to save and the range to show
    /// (`from`..`current`), or nil for no card this launch.
    public mutating func launch(previous: String?, current: String, enabled: Bool) -> (from: String, current: String)? {
        guard let now = WhatsNewVersion(current) else { return nil }
        let key = now.description
        guard let previous, let before = WhatsNewVersion(previous) else {
            // Fresh install: this version is never offered later.
            if !offered.contains(key) { offered.append(key) }
            return nil
        }
        if before < now {
            guard !offered.contains(key) else { return nil }
            offered.append(key)
            // Still up for the version before (0.1.10 → 0.1.11, not dismissed, then 0.1.12): it covers both.
            let since = pending ? (from ?? before.description) : before.description
            version = key
            from = since
            shownLaunches = 0
            dismissed = false
            guard enabled else {
                dismissed = true
                return nil
            }
        }
        // Same version (or a step back): the pending card keeps its launches.
        guard enabled, version == key, pending, let since = from else { return nil }
        shownLaunches += 1
        return (since, key)
    }

    public mutating func dismiss() { dismissed = true }
}

/// The appcast item's `<airc:highlights>`: a JSON array of `{"title", "lead", "icon"}` (and `detail`, which holds the
/// lead-in for 0.1.13–0.1.15 builds that read it as VoiceOver's text), the incoming release's first lines.
public enum WhatsNewAppcast {
    public static let namespace = "https://aircbrowser.com/xml-namespaces/airc"
    public static let element = "airc:highlights"
    /// Lines the Restart to Update card shows.
    public static let maxLines = 3

    /// The highlights in the element's text, at most three; [] for anything else (older feeds have none).
    public static func highlights(_ text: String?) -> [WhatsNewHighlight] {
        guard let data = text?.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8), !data.isEmpty,
              let list = try? JSONDecoder().decode([WhatsNewHighlight].self, from: data) else { return [] }
        return Array(list.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty && $0.title.count <= 60 }.prefix(maxLines))
    }

    /// From Sparkle's `propertiesDictionary` (its parser keeps unknown elements by their qualified name).
    public static func highlights(properties: [AnyHashable: Any]) -> [WhatsNewHighlight] {
        if let s = properties[element] as? String { return highlights(s) }
        let key = properties.keys.compactMap { $0 as? String }.first { $0.hasSuffix(":highlights") || $0 == "highlights" }
        return highlights(key.flatMap { properties[$0] as? String })
    }
}
