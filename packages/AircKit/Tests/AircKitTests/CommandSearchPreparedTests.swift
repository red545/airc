// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// keyframe2: ranking from a prepared run, with the character-mask prefilters, gives exactly the results of ranking
/// every candidate the old way.
final class CommandSearchPreparedTests: XCTestCase {
    private let words = ["Copy URL", "Capture Full Page", "Ångström", "Å la carte", "Å sign", "café", "Cafe\u{301} noir",
                         "日本語のページ", "🙂 smile", "👩‍💻 dev", "gap1k tab", "gap10k tab", "Reload", "Pin Tab", "Unpin",
                         "Move Tab to Work", "Developer Tools", "Ask This Page…", "naïve", "ﬁle", "ＷＩＤＥ", "x"]

    private func candidates() -> [CommandSearch.Candidate] {
        var out: [CommandSearch.Candidate] = []
        out.append(.init(id: "tab:a", kind: .openTab, title: "gap5k tab", subtitle: "example.com/gap5k", boost: 2))
        out.append(.init(id: "tab:b", kind: .openTab, title: "Ångström docs", subtitle: "angstrom.example"))
        for (i, w) in words.enumerated() {
            out.append(.init(id: "action:\(i)", kind: .action, title: w,
                             keywords: [words[(i + 3) % words.count].lowercased(), "k\(i)"]))
        }
        out.append(.init(id: "history:0", kind: .history, title: "gap7k history", subtitle: "history.example/gap7k"))
        return out
    }

    private let queries = ["g", "ga", "gap", "gap5", "gap5k", "gap1k", "å", "Å", "Å", "a", "ang", "cafe", "café", "caf",
                           "日本", "🙂", "👩‍💻", "smile", "cp", "cu", "copy", "pin", "unp", "tab", "zzz", "k1", "file",
                           "wide", "naive", "x", "page", "dev tools", "e\u{301}"]

    func testPreparedRunWithPrefiltersMatchesPlainRanking() {
        let all = candidates()
        let stable = 2..<(2 + words.count)
        let prepared = CommandSearch.PreparedRun(Array(all[stable]))
        for q in queries {
            CommandSearch.prefilters = false
            let plain = CommandSearch.rank(q, all, limit: 400)
            CommandSearch.prefilters = true
            var none: CommandSearch.Narrowing?
            let fast = CommandSearch.rank(q, all, limit: 400, stable: stable, narrowing: &none, prepared: prepared)
            XCTAssertEqual(fast, plain, "query \(q)")
        }
        CommandSearch.prefilters = true
    }

    func testPreparedRunWithNarrowingMatchesPlainRanking() {
        let all = candidates()
        let stable = 2..<(2 + words.count)
        let prepared = CommandSearch.PreparedRun(Array(all[stable]))
        var narrowing: CommandSearch.Narrowing?
        for q in ["c", "ca", "cap", "capt", "captu", "g", "ga", "gap", "gap1", "gap1k", "a", "an", "ang"] {
            let fast = CommandSearch.rank(q, all, limit: 400, stable: stable, narrowing: &narrowing, prepared: prepared)
            CommandSearch.prefilters = false
            let plain = CommandSearch.rank(q, all, limit: 400)
            CommandSearch.prefilters = true
            XCTAssertEqual(fast, plain, "query \(q)")
        }
    }

    func testMaskNeverRejectsAScoredMatch() {
        for w in words + ["https://history.example/gap3k", "Å", "Å", "A\u{30A}"] {
            for q in queries + ["Å", "A\u{30A}", "Å"] {
                CommandSearch.prefilters = false
                let plain = CommandSearch.score(q, in: w)
                CommandSearch.prefilters = true
                let fast = CommandSearch.score(q, in: w)
                XCTAssertEqual(fast?.score, plain?.score, "\(q) in \(w)")
                XCTAssertEqual(fast?.matches, plain?.matches, "\(q) in \(w)")
            }
        }
    }

    func testInlineTargetsMemoMatchesParsing() {
        for u in ["https://www.example.com:8443/a/b?c", "http://Example.ORG/", "file:///tmp/x", "https://日本.example/ページ",
                  "not a url", "https://history.example/gap3k"] {
            InlineCompletion.memoizesTargets = false
            let plain = InlineCompletion.targets(u)
            InlineCompletion.memoizesTargets = true
            let first = InlineCompletion.rememberedTargets(u), second = InlineCompletion.rememberedTargets(u)
            XCTAssertEqual(first?.host, plain?.host); XCTAssertEqual(first?.hostURL, plain?.hostURL)
            XCTAssertEqual(first?.address, plain?.address); XCTAssertEqual(second?.address, plain?.address)
            XCTAssertEqual(first == nil, plain == nil)
        }
    }

    func testBlendWithRememberedPagesMatchesParsing() {
        let personal = CommandSearch.rank("goo", [.init(id: "tab:1", kind: .openTab, title: "Google Docs", subtitle: "docs.google.com")])
        let sites = CommonSitesIndex.shared.snapshotNow().search("goo", region: nil, limit: 4)
        XCTAssertFalse(sites.isEmpty)
        let urls = ["https://www.google.com/", "https://docs.google.com/document/d/1", "not a url", "https://mail.google.com/mail/u/0/"]
        CommandSearch.memoizesPages = false
        let plain = CommandSearch.blend(personal, sites: sites, personalURLs: urls)
        CommandSearch.memoizesPages = true
        XCTAssertEqual(CommandSearch.blend(personal, sites: sites, personalURLs: urls), plain)
        XCTAssertEqual(CommandSearch.blend(personal, sites: sites, personalURLs: urls), plain)
    }
}
