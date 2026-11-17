// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// One search engine from a Chromium-family profile (Arc, Chrome, Brave…), as Airc can use it (C08b).
public struct ImportedSearchEngine: Codable, Sendable, Equatable {
    public var name: String
    /// The shortcut typed before Tab in Chromium's omnibox ("yt"); may be empty for a default with none.
    public var keyword: String
    /// The search page with `%s` where the query goes, https only (checked by `ChromiumSearchEngines.template`).
    /// Empty for a known engine whose own template isn't needed.
    public var template: String
    /// AircKit's `SearchEngine` raw value ("duckDuckGo") when this is one of the picker's engines, matched by Chromium's
    /// prepopulate_id or by host and path.
    public var known: String?
    /// Its suggestion endpoint (`suggest_url`) with `%s` for the query, checked as `template` is; nil when it has none, it
    /// isn't safe to keep, or this is a picker engine (Airc asks the picker's engines at its own addresses).
    public var suggest: String? = nil
}

/// A profile's search engines: its default and the shortcuts the user made. Chromium's prepopulated engines that aren't
/// the default, its starter pack (@bookmarks, @tabs…), policy engines and the site shortcuts it adds by itself (left
/// inactive, as Chromium's settings list them) are not part of it.
public struct ImportedSearchEngines: Codable, Sendable, Equatable {
    /// nil: the profile never chose one (Chromium then uses its region's first engine), or it couldn't be read.
    public var defaultEngine: ImportedSearchEngine?
    public var custom: [ImportedSearchEngine] = []
    /// Engines left out because their address isn't a safe https search page (javascript:, http:, no {searchTerms}…).
    public var rejected = 0

    public init(defaultEngine: ImportedSearchEngine? = nil, custom: [ImportedSearchEngine] = [], rejected: Int = 0) {
        self.defaultEngine = defaultEngine
        self.custom = custom
        self.rejected = rejected
    }

    public var isEmpty: Bool { defaultEngine == nil && custom.isEmpty }
}

/// Chromium's search engines (components/search_engines): `Web Data`'s `keywords` table, and the default in
/// `Preferences` — `default_search_provider.guid` (a row's sync_guid), else the saved copy
/// `default_search_provider_data.template_url_data`; very old profiles keep the row's id in `Web Data`'s `meta`
/// ("Default Search Provider ID"). Arc's per-profile "Default Search Engine" is a view of the same TemplateURLService
/// (C08), so this reads Arc, Chrome and Brave alike. `Web Data` is read from a private copy (the browser may hold it
/// locked); nothing is written.
public enum ChromiumSearchEngines {
    /// Chromium 156's prepopulate_id → AircKit `SearchEngine` raw value (third_party/search_engines_data
    /// prepopulated_engines.json).
    static let prepopulated: [Int: String] = [
        1: "google", 2: "yahoo", 3: "bing", 92: "duckDuckGo", 101: "ecosia", 109: "brave", 113: "startpage", 115: "kagi",
        117: "perplexity",
    ]

    /// Host (without "www.") and path of each picker engine's results page, for engines without a known prepopulate_id
    /// (Brave's own numbering, a hand-added copy of DuckDuckGo).
    static let pages: [(host: String, path: String, engine: String)] = [
        ("google.com", "/search", "google"), ("bing.com", "/search", "bing"), ("duckduckgo.com", "/", "duckDuckGo"),
        ("ecosia.org", "/search", "ecosia"), ("search.brave.com", "/search", "brave"), ("search.yahoo.com", "/search", "yahoo"),
        ("startpage.com", "/sp/search", "startpage"), ("startpage.com", "/do/search", "startpage"), ("kagi.com", "/search", "kagi"),
        ("perplexity.ai", "/search", "perplexity"), ("perplexity.ai", "/", "perplexity"),
    ]

    public static let maxTemplateLength = 2048
    /// More shortcuts than anyone types; a damaged or crafted table stops here.
    public static let maxCustom = 500

    /// The profile in `folder`'s engines; nil when it has neither `Web Data` nor a default in `Preferences`. Throws
    /// when `Web Data` is there but can't be copied or read (the caller warns), or for cancellation.
    public static func read(profile folder: URL, tempRoot: URL) throws -> ImportedSearchEngines? {
        let prefs = preferences(folder)
        let webData = folder.appendingPathComponent("Web Data")
        var rows: [Row] = []
        var metaDefault: String?
        if regularFile(webData) {
            let db = try DatabaseCopy(webData, tempRoot: tempRoot)
            rows = try db.rows("""
                SELECT * FROM keywords ORDER BY id LIMIT 5000
                """).map(Row.init)
            metaDefault = (try? db.rows("SELECT value FROM meta WHERE key = 'Default Search Provider ID'"))?
                .first?["value"].flatMap { String(data: $0, encoding: .utf8) }
        } else if prefs == nil {
            return nil
        }
        return engines(rows: rows, preferences: prefs ?? [:], metaDefaultID: metaDefault)
    }

    /// One `keywords` row, by column name (columns a version lacks read as empty/0).
    struct Row {
        var values: [String: Data]
        init(_ values: [String: Data]) { self.values = values }
        init(dict: Obj) {
            values = [:]
            for (k, v) in dict {
                if let s = v as? String { values[k] = Data(s.utf8) }
                else if let n = v as? NSNumber { values[k] = Data(n.stringValue.utf8) }
            }
        }
        func string(_ k: String) -> String { values[k].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        func int(_ k: String) -> Int {
            let s = string(k)
            return Int(s) ?? (s == "true" ? 1 : 0)
        }
    }

    static func engines(rows: [Row], preferences prefs: Obj, metaDefaultID: String?) -> ImportedSearchEngines {
        var out = ImportedSearchEngines()
        let dsp = obj(prefs["default_search_provider"])
        let data = obj(obj(prefs["default_search_provider_data"])["template_url_data"])
        // Chromium's order: the GUID pref points at a row; the saved data stands in when the row is gone; the meta id
        // is from before both.
        let guid = nonempty(dsp["guid"]) ?? nonempty(dsp["synced_guid"]) ?? nonempty(data["synced_guid"])
        var defaultRow = guid.flatMap { g in rows.first { $0.string("sync_guid") == g } }
        if defaultRow == nil, !data.isEmpty { defaultRow = Row(dict: data) }
        if defaultRow == nil, let id = metaDefaultID, !id.isEmpty, id != "0" { defaultRow = rows.first { $0.string("id") == id } }
        let defaultGUID = defaultRow.map { r in [r.string("sync_guid"), r.string("synced_guid")].first { !$0.isEmpty } ?? "" }

        if let r = defaultRow {
            // A default set by policy isn't the user's to bring along.
            if r.int("created_by_policy") == 0, r.int("enforced_by_policy") == 0 {
                if let e = engine(r, isDefault: true) { out.defaultEngine = e } else { out.rejected += 1 }
            }
        }
        var keywords = Set<String>()
        if let k = out.defaultEngine?.keyword, !k.isEmpty { keywords.insert(k.lowercased()) }
        for r in rows {
            guard out.custom.count < maxCustom else { break }
            if let defaultGUID, !defaultGUID.isEmpty, r.string("sync_guid") == defaultGUID { continue }
            guard isUserEngine(r) else { continue }
            guard let e = engine(r, isDefault: false), e.known == nil || !e.template.isEmpty else { out.rejected += 1; continue }
            let k = e.keyword.lowercased()
            guard !k.isEmpty, keywords.insert(k).inserted else { continue }
            out.custom.append(e)
        }
        return out
    }

    /// A shortcut the user made or kept: not prepopulated, not the starter pack, not from policy or Play, not one Chromium
    /// added by itself and left inactive (`safe_for_autoreplace` with `is_active` unspecified: chrome://settings shows
    /// those under "Inactive shortcuts", and the omnibox doesn't run them), and not one the user switched off.
    static func isUserEngine(_ r: Row) -> Bool {
        guard r.int("prepopulate_id") == 0, r.int("starter_pack_id") == 0, r.int("created_by_policy") == 0,
              r.int("enforced_by_policy") == 0, r.int("featured_by_policy") == 0, r.int("created_from_play_api") == 0 else { return false }
        let active = r.int("is_active")   // 0 unspecified, 1 active, 2 deactivated by the user
        if active == 2 { return false }
        return r.int("safe_for_autoreplace") == 0 || active == 1
    }

    static func engine(_ r: Row, isDefault: Bool) -> ImportedSearchEngine? {
        let name = String(r.string("short_name").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let keyword = r.string("keyword").trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = r.string("url")
        let prepopulateID = r.int("prepopulate_id")
        if let known = prepopulated[prepopulateID] ?? knownPage(raw) {
            // A picker engine: Airc's own address for it, never the profile's copy.
            return ImportedSearchEngine(name: name, keyword: keyword, template: isDefault ? "" : (template(raw, prepopulated: prepopulateID > 0) ?? ""), known: known)
        }
        guard let t = template(raw, prepopulated: prepopulateID > 0) else { return nil }
        let fallback = URLComponents(string: t.replacingOccurrences(of: "%s", with: "x"))?.host ?? "Search"
        // Suggestions only from where a query may go: an https endpoint with the query outside its host.
        // (`Web Data` calls it suggest_url; the saved default in Preferences, suggestions_url.)
        let rawSuggest = r.string("suggest_url").isEmpty ? r.string("suggestions_url") : r.string("suggest_url")
        let suggest = template(rawSuggest, prepopulated: prepopulateID > 0)
        return ImportedSearchEngine(name: name.isEmpty ? fallback : name, keyword: keyword, template: t, known: nil, suggest: suggest)
    }

    /// The picker engine whose results page `raw` is, if any.
    static func knownPage(_ raw: String) -> String? {
        guard raw.lowercased().hasPrefix("https://"),
              let u = URLComponents(string: raw.replacingOccurrences(of: "{searchTerms}", with: "x")), let h = u.host?.lowercased() else { return nil }
        let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        let path = u.path.isEmpty ? "/" : u.path
        return pages.first { $0.host == host && $0.path == path }?.engine
    }

    /// A Chromium search address as an Airc template (`%s` for the query), or nil when it isn't safe to keep: not https
    /// (javascript:, data:, http:…), no `{searchTerms}`, a `%s` of its own, spaces or control characters, a placeholder
    /// in the host, or other placeholders Airc can't fill. Prepopulated engines' `{google:…}` parameters are dropped
    /// (they're optional extras), and `{inputEncoding}` is UTF-8, as Chromium fills it.
    public static func template(_ raw: String, prepopulated: Bool = false) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxTemplateLength, t.lowercased().hasPrefix("https://"), t.contains("{searchTerms}"),
              !t.contains("%s") else { return nil }
        guard !t.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        t = "https" + t.dropFirst(5)
        t = t.replacingOccurrences(of: "{inputEncoding}", with: "UTF-8")
        if prepopulated {
            while let r = t.range(of: #"\{google:[A-Za-z]+\}"#, options: .regularExpression) { t.removeSubrange(r) }
            t = t.replacingOccurrences(of: "&&", with: "&")
        }
        t = t.replacingOccurrences(of: "{searchTerms}", with: "%s")
        guard !t.contains("{"), !t.contains("}") else { return nil }
        let authority = t.dropFirst("https://".count).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty, !authority.contains("%s"), !authority.contains("@") else { return nil }
        let sample = t.replacingOccurrences(of: "%s", with: "x")
        guard let u = URLComponents(string: sample), let host = u.host, !host.isEmpty, u.scheme == "https", URL(string: sample) != nil
        else { return nil }
        return t
    }

    static func preferences(_ folder: URL) -> Obj? {
        let url = folder.appendingPathComponent("Preferences")
        // Chromium writes Preferences whole (ImportantFileWriter), so it's read in place.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard regularFile(url), size <= BrowserImporter.maxFileSize, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? Obj
    }

    static func regularFile(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return v.isRegularFile == true && v.isSymbolicLink != true
    }
}
