// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// cbrows: ranking with a narrowing (only what the previous query matched, when the new one extends it) gives exactly
/// the full ranking, key after key, whatever the queries do: extend, shrink, replace, add spaces or accents.
final class CommandSearchNarrowingTests: XCTestCase {
    private func candidates() -> [CommandSearch.Candidate] {
        let words = ["page", "title", "docs", "issue", "pull", "search", "news", "video", "inbox", "settings", "Café", "naïve"]
        var c: [CommandSearch.Candidate] = [
            .init(id: "tab:1", kind: .openTab, title: "GitHub", subtitle: "github.com", boost: 1),
            .init(id: "tab:2", kind: .openTab, title: "Site 12 page", subtitle: "site12.example.com"),
        ]
        for i in 0..<400 {
            c.append(.init(id: "action:\(i)", kind: .action, title: "\(words[i % words.count].capitalized) \(words[(i / 12) % words.count]) \(i)",
                           keywords: i % 3 == 0 ? ["git", "copy url"] : ["tidy \(i % 5)"]))
        }
        c.append(.init(id: "history:0", kind: .history, title: "Page title 7", subtitle: "site1.example.com/path/7", boost: 3))
        return c
    }

    func testNarrowedRankingMatchesFullRanking() {
        let all = candidates()
        let stable = 2..<402
        var narrowing: CommandSearch.Narrowing?
        let queries = ["g", "gi", "git", "gith", "githu", "github", "site1", "site12", "page", "page ", "page t", "page ti",
                       "pa", "p", "", "c", "ca", "caf", "café", "cafe x", "na", "naï", "naïv", "  ti", "tidy 3", "tidy 31",
                       "copy", "copy url", "x", "xy", "s", "se", "set", "sett"]
        for q in queries {
            let narrowed = CommandSearch.rank(q, all, limit: 400, stable: stable, narrowing: &narrowing)
            let full = CommandSearch.rank(q, all, limit: 400)
            XCTAssertEqual(narrowed, full, "“\(q)”")
        }
    }

    func testNarrowingSkipsWhatTheShorterQueryMissed() {
        let all = candidates()
        var narrowing: CommandSearch.Narrowing?
        _ = CommandSearch.rank("vid", all, stable: 2..<402, narrowing: &narrowing)
        let shorter = narrowing?.count ?? -1
        _ = CommandSearch.rank("video", all, stable: 2..<402, narrowing: &narrowing)
        XCTAssertGreaterThan(shorter, 0)
        XCTAssertLessThanOrEqual(narrowing?.count ?? -1, shorter)
    }
}
