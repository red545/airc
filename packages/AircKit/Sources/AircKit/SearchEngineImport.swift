// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// C08b: another browser's search engines, brought into a profile. Engines Airc's picker has become the profile's
/// built-in engine; any other default, and every shortcut the user made ("yt" → YouTube), becomes a site search
/// (Settings → Site Search), the default one made the default as P07d does. Importing again updates what an import
/// added and never touches a site the user added or edited in Airc.
public struct SearchEngineImport: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var name: String
        /// May be empty for a default; one is made from the site's host.
        public var keyword: String
        /// The search page with `%s` (or Chrome's `{searchTerms}`).
        public var template: String

        public init(name: String, keyword: String, template: String) {
            self.name = name
            self.keyword = keyword
            self.template = template
        }
    }

    public enum Default: Equatable, Sendable {
        case engine(SearchEngine)
        case site(Entry)
    }

    /// nil: keep the profile's default as it is (the source never chose one).
    public var defaultSearch: Default?
    public var shortcuts: [Entry]

    public init(defaultSearch: Default?, shortcuts: [Entry]) {
        self.defaultSearch = defaultSearch
        self.shortcuts = shortcuts
    }

    /// What applying it did, counts only.
    public struct Outcome: Equatable, Sendable {
        /// The built-in engine to set on the profile, when the default is one of the picker's.
        public var engine: SearchEngine?
        /// The site search that's now the default, when the default isn't one of the picker's.
        public var defaultSite: SiteSearch?
        public var added = 0
        public var updated = 0
        /// Already there (same address), so nothing changed.
        public var existing = 0
        /// Left out: the shortcut belongs to another site in Airc, or the entry isn't a usable site search.
        public var skipped = 0
    }

    public static let idPrefix = "import."
}

extension SiteSearchSettings {
    /// Adds `engines`' shortcuts to `profileID`'s site searches and makes its default the default. The caller sets the
    /// profile's built-in engine to `outcome.engine` when there is one (this clears a site default for it).
    @discardableResult
    public mutating func apply(_ engines: SearchEngineImport, to profileID: String) -> SearchEngineImport.Outcome {
        var out = SearchEngineImport.Outcome()
        for e in engines.shortcuts {
            switch merge(e, into: profileID) {
            case .added: out.added += 1
            case .updated: out.updated += 1
            case .existing: out.existing += 1
            case .skipped: out.skipped += 1
            }
        }
        switch engines.defaultSearch {
        case .engine(let engine)?:
            out.engine = engine
            setDefault(nil, for: profileID)
        case .site(var e)?:
            if e.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { e.keyword = freeKeyword(for: e.template, in: profileID) }
            let r = merge(e, into: profileID)
            if let s = r.site, setDefault(s.id, for: profileID) {
                out.defaultSite = s
                switch r {
                case .added: out.added += 1
                case .updated: out.updated += 1
                default: out.existing += 1
                }
            } else {
                out.skipped += 1
            }
        case nil:
            break
        }
        return out
    }

    private enum Merge {
        case added(SiteSearch), updated(SiteSearch), existing(SiteSearch), skipped
        var site: SiteSearch? {
            switch self {
            case .added(let s), .updated(let s), .existing(let s): s
            case .skipped: nil
            }
        }
    }

    /// One entry into the list: the same address already there (under any shortcut) is kept as it is; a shortcut an
    /// earlier import added is updated; a shortcut another site has is left to that site.
    private mutating func merge(_ e: SearchEngineImport.Entry, into profileID: String) -> Merge {
        guard case .success(let template) = SiteSearchTemplate.normalize(e.template), template.hasPrefix("https://") else { return .skipped }
        let list = searches(for: profileID)
        if let same = list.first(where: { $0.template == template }) { return .existing(same) }
        let k = e.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if let taken = list.first(where: { $0.keyword.lowercased() == k.lowercased() }) {
            guard taken.id.hasPrefix(SearchEngineImport.idPrefix) else {
                // Airc's own entry for the same site (its seeded YouTube for Arc's "yt") is the same search.
                return taken.host != nil && taken.host == SiteSearchTemplate.host(of: template) ? .existing(taken) : .skipped
            }
            if case .success(let s) = update(taken.id, name: e.name, keyword: k, template: template, in: profileID) { return .updated(s) }
            return .skipped
        }
        guard case .success(var s) = check(name: e.name, keyword: k, template: template, for: profileID) else { return .skipped }
        s.id = SearchEngineImport.idPrefix + k.lowercased()
        if list.contains(where: { $0.id == s.id }) { s.id += "." + UUID().uuidString.prefix(8) }
        let added = s
        var p = profiles[profileID] ?? ProfileSearches(searches: Self.defaults)
        p.searches.append(added)
        profiles[profileID] = p
        return .added(added)
    }

    /// A shortcut for a default that had none: the site's name ("example" for search.example.com), then "example2"….
    private func freeKeyword(for template: String, in profileID: String) -> String {
        let host = SiteSearchTemplate.host(of: SiteSearchTemplate.normalize(template).successValue ?? template) ?? "search"
        let parts = host.split(separator: ".")
        let base = String(parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? "search").prefix(30)
        let taken = Set(searches(for: profileID).map { $0.keyword.lowercased() })
        if !taken.contains(base.lowercased()) { return String(base) }
        var n = 2
        while taken.contains("\(base)\(n)".lowercased()) { n += 1 }
        return "\(base)\(n)"
    }
}

private extension Result {
    var successValue: Success? { if case .success(let v) = self { v } else { nil } }
}
