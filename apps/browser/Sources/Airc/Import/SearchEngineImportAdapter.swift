// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircImport
import AircKit
import Foundation

/// C08b: each imported profile's search engines (Arc's, Chrome's, Brave's): its default becomes the Airc profile's
/// built-in engine (Settings › Profiles › Search engine) when the picker has it, else a site search made the default;
/// its own shortcuts become site searches (Settings › Site Search), so "yt" + Tab works in the Command Bar as in Arc.
enum SearchEngineImportAdapter {
    static func plan(_ e: ImportedSearchEngines) -> SearchEngineImport {
        let defaultSearch: SearchEngineImport.Default? = e.defaultEngine.flatMap { d in
            if let raw = d.known, let engine = SearchEngine(rawValue: raw) { return .engine(engine) }
            guard !d.template.isEmpty else { return nil }
            return .site(.init(name: d.name, keyword: d.keyword, template: d.template, suggest: d.suggest))
        }
        return SearchEngineImport(defaultSearch: defaultSearch,
                                  shortcuts: e.custom.filter { !$0.template.isEmpty }.map { .init(name: $0.name, keyword: $0.keyword, template: $0.template, suggest: $0.suggest) })
    }

    struct Summary: Equatable {
        var profiles = 0
        var defaults = 0
        var shortcuts = 0
        var skipped = 0
    }

    /// Airc profile ID → engines. Changes only the profiles named. Called on the main thread (the import step).
    static func apply(_ mapped: [String: ImportedSearchEngines], store: SpacesStore, settings: AppSettings) -> Summary {
        var summary = Summary()
        var values = settings.values.siteSearch
        for (pid, engines) in mapped.sorted(by: { $0.key < $1.key }) where store.profile(pid) != nil {
            let outcome = values.apply(plan(engines), to: pid)
            if let engine = outcome.engine { try? store.updateProfile(pid) { $0.searchEngine = engine } }
            summary.profiles += 1
            if outcome.engine != nil || outcome.defaultSite != nil { summary.defaults += 1 }
            summary.shortcuts += outcome.added + outcome.updated + outcome.existing - (outcome.defaultSite == nil ? 0 : 1)
            summary.skipped += outcome.skipped
        }
        settings.values.siteSearch = values
        // Counts only: never an engine's name, shortcut or address.
        NSLog("[import] search engines: %ld profiles, %ld defaults, %ld shortcuts, %ld left out",
              summary.profiles, summary.defaults, summary.shortcuts, summary.skipped)
        return summary
    }

    /// "2 search engine shortcuts" for the import's summary.
    static func describe(_ s: Summary) -> String? {
        guard s.defaults + s.shortcuts > 0 else { return nil }
        var parts: [String] = []
        if s.defaults > 0 { parts.append(BrowserImportAdapter.plural(s.defaults, "default search engine")) }
        if s.shortcuts > 0 { parts.append(BrowserImportAdapter.plural(s.shortcuts, "search shortcut")) }
        return parts.joined(separator: " · ")
    }
}
