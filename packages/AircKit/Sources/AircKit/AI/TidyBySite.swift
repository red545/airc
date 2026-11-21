// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Tidy Tabs without a language model (docs/user/sidebar.md, "Keeping your sidebar tidy"): when Apple Intelligence
/// isn't on, Tidy groups Today's pages by site instead of by topic. It is a `TidyTabsModel` so the planner, the plan,
/// the preview and ⌘Z are exactly Tidy's; it reads only each tab's host (never a title) and runs instantly.
///
/// - A site's folder needs two different pages of it (`TidyTabsRules.minPagesPerFolder`), as a topic folder does.
/// - The folder is named after the site's host without "www." ("docs.example.com"); a host too long for a folder name
///   (`TidyTabsRules.maxNameLength`) uses its last two labels.
/// - The same tabs make the same folders: sites go in Today order, by the first of their pages.
public struct TidyTabsBySite: TidyTabsModel {
    public init() {}

    public func folders(for request: TidyTabsRequest) async throws -> [TidyTabsFolderAnswer] {
        Self.answers(for: request)
    }

    public static func answers(for request: TidyTabsRequest) -> [TidyTabsFolderAnswer] {
        var order: [String] = []
        var numbers: [String: [Int]] = [:]
        for t in request.tabs where !t.host.isEmpty {
            if numbers[t.host] == nil { order.append(t.host) }
            numbers[t.host, default: []].append(t.number)
        }
        return order.compactMap { host in
            guard let n = numbers[host], n.count >= TidyTabsRules.minPagesPerFolder else { return nil }
            return TidyTabsFolderAnswer(name: folderName(host: host), tabs: n)
        }
    }

    /// "docs.example.com" stays as it is; a host longer than a folder name may be keeps its last two labels.
    public static func folderName(host: String) -> String {
        guard host.count > TidyTabsRules.maxNameLength else { return host }
        let labels = host.split(separator: ".")
        return labels.suffix(2).joined(separator: ".")
    }
}

/// When the Today list is long enough for the sidebar's tidy card (AI/TidyHint.swift) to offer help, and what it
/// offers: pure rules, so the tests and the card agree.
public enum TidyHintRules {
    /// Loose Today tabs (not in a Today folder, not pinned) that make the list long.
    public static let tabThreshold = 12
    /// With the Today list taller than the sidebar, this many loose tabs are enough.
    public static let overflowThreshold = 6
    /// Archive offers: the longest of these that would archive at least `archiveMinimum` tabs.
    public static let archiveAges: [TimeInterval] = [6 * 3600, 3 * 3600, 3600]
    public static let archiveMinimum = 3
    /// Pin to Favorites offers at most this many sites, each with at least this many Today tabs.
    public static let maxPinSuggestions = 2
    public static let pinMinimumTabs = 2

    public static func isLong(looseTabs: Int, overflows: Bool) -> Bool {
        looseTabs >= tabThreshold || (overflows && looseTabs >= overflowThreshold)
    }

    /// The day key the card's once-a-day rule uses (local calendar day).
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The archive offer: the age and the tabs (oldest view first) for the longest age in `archiveAges` that catches
    /// at least `archiveMinimum` of `tabs`, never one in `protected` (the page on screen, one playing sound). Nil when
    /// none does.
    public static func archiveOffer(_ tabs: [LiveTab], now: Date, protected: Set<String>) -> (age: TimeInterval, ids: [String])? {
        for age in archiveAges {
            let ids = tabs.filter { !protected.contains($0.id) && now.timeIntervalSince($0.lastActiveAt) >= age }
                .sorted { $0.lastActiveAt < $1.lastActiveAt }.map(\.id)
            if ids.count >= archiveMinimum { return (age, ids) }
        }
        return nil
    }

    /// "3 h": the card's line.
    public static func shortAgeLabel(_ age: TimeInterval) -> String { "\(Int((age / 3600).rounded())) h" }

    /// "3 hours", "1 hour".
    public static func ageLabel(_ age: TimeInterval) -> String {
        let h = Int((age / 3600).rounded())
        return h == 1 ? "1 hour" : "\(h) hours"
    }

    /// The sites to offer as Favorites: hosts with the most Today tabs (at least `pinMinimumTabs`), ties by the most
    /// recent view, skipping hosts already a Favorite. Each with the tab that would become the Favorite (its most
    /// recently viewed one).
    public static func pinSuggestions(_ tabs: [LiveTab], favoriteHosts: Set<String>) -> [(host: String, tabID: String)] {
        var byHost: [String: [LiveTab]] = [:]
        for t in tabs where TidyTabsRules.isSortable(url: t.url) {
            let h = TidyTabsRules.host(of: t.url)
            guard !h.isEmpty, !favoriteHosts.contains(h) else { continue }
            byHost[h, default: []].append(t)
        }
        let ranked = byHost.filter { $0.value.count >= pinMinimumTabs }.map { host, ts -> (String, Int, Date, String) in
            let newest = ts.max { $0.lastActiveAt < $1.lastActiveAt }!
            return (host, ts.count, newest.lastActiveAt, newest.id)
        }.sorted { ($0.1, $0.2, $1.0) > ($1.1, $1.2, $0.0) }
        return ranked.prefix(maxPinSuggestions).map { ($0.0, $0.3) }
    }
}
