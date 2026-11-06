// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import Foundation

/// Search suggestions for the Command Bar (CB-1) from the profile's search engine. Per profile: each profile has its
/// own cookie-less session and cache, so nothing typed in one profile informs another's suggestions. Debounced
/// (30 ms: enough to coalesce a burst of keys, short enough for the ≤100 ms budget), and only the latest query's answer
/// is delivered. Opening the Command Bar connects to the engine ahead (`prewarm`), so the first answer doesn't pay for
/// DNS, TCP and TLS. Automated runs (test builds) use canned answers unless
/// `AIRC_LIVE_SUGGESTIONS=1`, so snapshots don't depend on the network.
final class SuggestionService {
    #if AIRC_TESTING
    static let shared = SuggestionService(canned: LaunchOptions.current.isAutomated
                                          && ProcessInfo.processInfo.environment["AIRC_LIVE_SUGGESTIONS"] != "1")
    #else
    static let shared = SuggestionService(canned: false)
    #endif
    /// Always the network (the snapshot scenario's one live check).
    static let live = SuggestionService(canned: false)

    static let debounce: TimeInterval = 0.03
    private let canned: Bool
    private var sessions: [String: URLSession] = [:]
    private var cache: [String: [String: [String]]] = [:]   // profile → query → suggestions
    private var pending: DispatchWorkItem?
    private var task: URLSessionDataTask?
    private var generation = 0

    init(canned: Bool) {
        self.canned = canned
    }

    private func session(for profileID: String) -> URLSession {
        if let s = sessions[profileID] { return s }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        let s = URLSession(configuration: config)
        sessions[profileID] = s
        return s
    }

    /// Opens the connection to the engine's suggestion host (a HEAD request to its root: no query is sent), so the first
    /// keystroke's request reuses it. Chrome preconnects to the search engine the same way.
    func prewarm(engine: SearchEngine, profileID: String) {
        guard !canned, let probe = SearchSuggestions.url(for: "a", engine: engine),
              var root = URLComponents(url: probe, resolvingAgainstBaseURL: false) else { return }
        root.path = "/"
        root.query = nil
        guard let url = root.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        session(for: profileID).dataTask(with: request).resume()
    }

    /// Calls `completion` on the main thread with up to four suggestions, or not at all if a newer query came first.
    func fetch(_ query: String, engine: SearchEngine, profileID: String, completion: @escaping ([String]) -> Void) {
        let q = query.trimmingCharacters(in: .whitespaces)
        pending?.cancel()
        task?.cancel()
        generation += 1
        let gen = generation
        if let hit = cache[profileID]?[q.lowercased()] { return completion(hit) }
        if canned {
            let list = Self.cannedSuggestions(for: q)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
                guard self?.generation == gen else { return }
                completion(list)
            }
            return
        }
        guard let url = SearchSuggestions.url(for: q, engine: engine) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let t = self.session(for: profileID).dataTask(with: url) { data, _, _ in
                let list = data.map { SearchSuggestions.parse($0, query: q) } ?? []
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.cache[profileID, default: [:]][q.lowercased()] = list
                    if (self.cache[profileID]?.count ?? 0) > 200 { self.cache[profileID] = [:] }
                    completion(list)
                }
            }
            self.task = t
            t.resume()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    func clear(profileID: String) {
        cache[profileID] = nil
        sessions.removeValue(forKey: profileID)?.invalidateAndCancel()
    }

    static func cannedSuggestions(for q: String) -> [String] {
        let l = q.lowercased()
        let table: [String: [String]] = [
            "wiki": ["wikipedia", "wiki how", "wikimedia commons", "wikitravel lisbon"],
            "lis": ["lisbon weather", "lisbon tram 28", "lisbon airport"],
        ]
        if let hit = table.first(where: { l.hasPrefix($0.key) })?.value { return hit }
        return [l + " meaning", l + " near me"]
    }
}
