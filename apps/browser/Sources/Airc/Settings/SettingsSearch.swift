// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// settingsux: Settings search (the field at the top of the Settings sidebar, ⌘F). Panes, section titles, row labels,
/// their descriptions and keywords, from SettingsSearchCatalog.swift (generated from the panes' sources by
/// scripts/settings-search-index.py) plus the Shortcuts pane's commands. The index is built once, on first use.
enum SettingsSearch {
    struct Entry: Equatable {
        enum Kind: Equatable { case page, section, row }
        let kind: Kind
        let page: SettingsPage
        /// What a result shows: the pane's, section's or row's own title.
        let title: String
        /// The section a row is in (nil for panes and sections, and rows outside a section).
        let section: String?
        /// The section's help or the row's subtitle.
        let detail: String?
        /// Other titles the same row shows in another state ("Open links from other apps in Airc"), searched too and
        /// highlighted when shown.
        var alternates: [String] = []
        var keywords: [String] = []

        static func section(_ page: SettingsPage, _ title: String, detail: String? = nil, alternates: [String] = []) -> Entry {
            Entry(kind: .section, page: page, title: title, section: nil, detail: detail, alternates: alternates)
        }
        static func row(_ page: SettingsPage, _ title: String, section: String? = nil, detail: String? = nil, alternates: [String] = []) -> Entry {
            Entry(kind: .row, page: page, title: title, section: section, detail: detail, alternates: alternates)
        }

        /// "Appearance › Window": where the result is, under its title.
        var path: String {
            switch kind {
            case .page: "Settings"
            case .section: page.title
            case .row: section.map { "\(page.title) › \($0)" } ?? page.title
            }
        }

        /// The view ids SettingsRoot scrolls to and highlights (SettingsSection's and the rows' `settingsAnchor`).
        var anchors: [String] {
            switch kind {
            case .page: []
            case .section: ([title] + alternates).map(SettingsSearch.sectionAnchor)
            case .row: ([title] + alternates).map(SettingsSearch.rowAnchor)
            }
        }
        /// Where to scroll: the row, else its section (a row that isn't shown now, like "Calendar access is off").
        var scrollTargets: [String] {
            kind == .row ? anchors + (section.map { [SettingsSearch.sectionAnchor($0)] } ?? []) : anchors
        }
    }

    static func sectionAnchor(_ title: String) -> String { title }   // whatsnew2's ids: a section's own title
    static func rowAnchor(_ title: String) -> String { "row:" + title }

    /// Words people use for a pane that its own text may not have.
    static let pageKeywords: [SettingsPage: [String]] = [
        .general: ["default browser", "updates", "nightly", "startup", "restore", "sounds", "haptics", "memory", "backup",
                   "developer", "picture in picture", "pip", "calendar", "meetings", "notes"],
        .boosts: ["boost", "boosts", "css", "javascript", "custom style", "zap", "font", "colour", "color", "site style"],
        .links: ["default browser", "little airc", "little arc", "peek", "air traffic control", "rules", "open links"],
        .profiles: ["profile", "account", "google", "search engine", "ad blocker", "adblock", "ads", "trackers", "cookies",
                    "clear history", "browsing data", "archive"],
        .siteSearch: ["site search", "search engine", "keyword", "shortcut", "tab to search", "google", "duckduckgo"],
        .spaces: ["space", "spaces", "profile", "rename", "delete", "reorder", "icon", "emoji"],
        .sync: ["icloud", "sync", "other mac", "devices", "backup"],
        .appearance: ["dark", "dark mode", "light", "light mode", "night", "theme", "color", "colour", "translucency",
                      "transparency", "sidebar", "right", "left", "app icon", "icon", "previews", "follow airc"],
        .ai: ["ai", "apple intelligence", "tidy", "summaries", "ask", "link previews", "instant links", "downloads",
              "agent", "api key", "claude", "openai", "model"],
        .agents: ["agents", "mcp", "claude", "claude code", "cursor", "codex", "ai apps", "tailscale", "pair", "automation"],
        .shortcuts: ["shortcut", "shortcuts", "keyboard", "keys", "hotkey", "key binding", "keybinding", "remap"],
        .importing: ["import", "arc", "chrome", "brave", "safari", "firefox", "bookmarks", "history", "export", "onboarding",
                     "passwords", "csv"],
        .passwords: ["password", "passwords", "1password", "bitwarden", "dashlane", "keychain", "login", "logins", "autofill",
                     "fill", "passkey", "passkeys", "password manager"],
        .privacy: ["privacy", "telemetry", "usage data", "analytics", "drm", "widevine", "netflix", "crash reports", "tracking"],
        .about: ["about", "version", "licenses", "credits", "acknowledgements"],
    ]

    /// Words for single rows (by title), where people search for something the label doesn't say.
    static let rowKeywords: [String: [String]] = [
        "Airc": ["dark mode", "light mode", "auto", "night", "appearance"],
        "Translucency": ["transparency", "vibrancy", "blur", "opaque"],
        "Sidebar position": ["right side", "left side", "move sidebar"],
        "Block ads and trackers": ["adblock", "ad blocker", "ublock", "easylist"],
        "Block cookie banners": ["cookie consent", "gdpr"],
        "Search suggestions": ["autocomplete"],
        "Unload tabs you haven't looked at for": ["sleep", "suspend", "discard", "memory saver"],
        "Update channel": ["beta", "nightly", "stable"],
        "Play protected content": ["drm", "widevine", "netflix", "spotify"],
        "Choose a password manager": ["1password", "bitwarden", "password", "autofill"],
        "Passwords from a CSV file": ["password", "import passwords"],
        "Share anonymous usage data": ["telemetry", "analytics"],
        "Open links in Peek": ["preview", "popup"],
        "Pop out videos and calls when you leave their tab": ["pip", "picture in picture", "video", "meet", "zoom"],
        "Shortcut": ["hotkey", "keyboard shortcut"],
    ]

    /// The whole index (built once).
    static var entries: [Entry] { index.entries }

    /// Results for `query`, best first: every word of it must start a word of the entry (title, section, pane,
    /// description or keywords). Ties keep the panes' own order.
    static func results(for query: String, limit: Int = 50) -> [Entry] {
        let words = Index.words(query)
        guard !words.isEmpty else { return [] }
        return index.search(words, phrase: Index.fold(query).trimmingCharacters(in: .whitespaces), limit: limit)
    }

    private static let index = Index(entries: buildEntries())

    static func buildEntries() -> [Entry] {
        var out: [Entry] = []
        for page in SettingsPage.allCases {
            out.append(Entry(kind: .page, page: page, title: page.title, section: nil, detail: nil, keywords: pageKeywords[page] ?? []))
            for var e in catalog where e.page == page {
                e.keywords = rowKeywords[e.title] ?? []
                if e.kind == .row, out.contains(where: { $0.kind == .row && $0.page == page && $0.title == e.title }) { continue }
                out.append(e)
            }
            if page == .shortcuts {
                // The Shortcuts pane lists every command by menu; their titles come from the menus, not the pane's source.
                for group in ShortcutCenter.groups {
                    out.append(.section(.shortcuts, group.title))
                    for c in group.commands where !c.id.isEmpty {
                        var e = Entry.row(.shortcuts, ShortcutCenter.title(c.id), section: group.title)
                        e.keywords = ["shortcut", "keyboard", "key"]
                        if !out.contains(where: { $0.kind == .row && $0.page == .shortcuts && $0.title == e.title }) { out.append(e) }
                    }
                }
            }
        }
        return out
    }

    final class Index {
        let entries: [Entry]
        /// Per entry: folded words of each field, by weight.
        private let fields: [[(weight: Double, words: [String])]]
        private let titles: [String]

        init(entries: [Entry]) {
            self.entries = entries
            fields = entries.map { e in
                [(100, Self.words(([e.title] + e.alternates).joined(separator: " "))),
                 (55, Self.words(e.section ?? "")),
                 (45, Self.words(e.page.title)),
                 (40, Self.words(e.keywords.joined(separator: " "))),
                 (12, Self.words(e.detail ?? ""))]
            }
            titles = entries.map { Self.fold($0.title) }
        }

        func search(_ query: [String], phrase: String, limit: Int) -> [Entry] {
            var scored: [(score: Double, i: Int)] = []
            for (i, f) in fields.enumerated() {
                var total = 0.0
                for q in query {
                    var best = 0.0
                    for field in f where field.weight > best {
                        if field.words.contains(where: { $0.hasPrefix(q) }) {
                            best = field.weight + (field.words.contains(q) ? 5 : 0)
                        }
                    }
                    if best == 0 { total = 0; break }
                    total += best
                }
                guard total > 0 else { continue }
                let e = entries[i]
                if titles[i] == phrase { total += 60 } else if titles[i].hasPrefix(phrase) { total += 30 }
                if e.kind == .page { total += 8 } else if e.kind == .section { total += 4 }
                scored.append((total, i))
            }
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }
            return scored.prefix(limit).map { entries[$0.i] }
        }

        static func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .replacingOccurrences(of: "’", with: "'")
        }

        static func words(_ s: String) -> [String] {
            fold(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map {
                String($0).replacingOccurrences(of: "'", with: "")
            }.filter { !$0.isEmpty }
        }
    }
}
