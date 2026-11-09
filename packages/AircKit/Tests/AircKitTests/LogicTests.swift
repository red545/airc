// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class URLRulesTests: XCTestCase {
    func testDisplayHost() {
        XCTAssertEqual(URLRules.displayHost("https://www.github.com/airc"), "github.com")
        XCTAssertEqual(URLRules.displayHost("http://localhost:5173/app"), "localhost:5173")
        XCTAssertEqual(URLRules.displayHost("about:blank"), "")
    }

    func testNormalizeInput() {
        XCTAssertEqual(URLRules.normalizeInput("github.com"), "https://github.com")
        XCTAssertEqual(URLRules.normalizeInput("localhost:3000/x"), "http://localhost:3000/x")
        XCTAssertEqual(URLRules.normalizeInput("https://a.b/c?d"), "https://a.b/c?d")
        XCTAssertNil(URLRules.normalizeInput("arc browser"))
        XCTAssertNil(URLRules.normalizeInput("hello"))
        XCTAssertEqual(URLRules.resolve("arc browser", engine: .duckDuckGo)?.absoluteString,
                       "https://duckduckgo.com/?q=arc%20browser")
        XCTAssertEqual(URLRules.resolve("c++ & rust", engine: .google)?.absoluteString,
                       "https://www.google.com/search?q=c%2B%2B%20%26%20rust")
    }

    func testDrift() {
        XCTAssertFalse(URLRules.isDrifted(saved: "https://mail.google.com/mail/u/0/#inbox",
                                          current: "https://mail.google.com/mail/u/0/#label/x"))
        XCTAssertFalse(URLRules.isDrifted(saved: "https://calendar.google.com/calendar/r",
                                          current: "https://calendar.google.com/calendar/r/week/2026/11/4"))
        XCTAssertTrue(URLRules.isDrifted(saved: "https://youtube.com/watch?v=a", current: "https://youtube.com/watch?v=b"))
        XCTAssertTrue(URLRules.isDrifted(saved: "https://a.com/x", current: "https://b.com/x"))
        XCTAssertFalse(URLRules.isDrifted(saved: "https://a.com/x#top", current: "https://a.com/x/"))
    }

    func testUnreadCount() {
        XCTAssertEqual(URLRules.unreadCount(fromTitle: "Inbox (3) - me@example.com - Gmail"), 3)
        XCTAssertEqual(URLRules.unreadCount(fromTitle: "(12) Home / X"), 12)
        XCTAssertNil(URLRules.unreadCount(fromTitle: "Inbox - Gmail"))
        XCTAssertNil(URLRules.unreadCount(fromTitle: "Inbox (0)"))
    }

    func testMarkdown() {
        XCTAssertEqual(URLRules.markdownLink(title: "A [b]", url: "https://a.com"), "[A \\[b\\]](https://a.com)")
    }
}

final class MotionTests: XCTestCase {
    func testCriticallyDampedSpaceSettle() {
        let s = Spring(response: 0.19, dampingRatio: 1)  // Arc's Space settle
        XCTAssertEqual(s.omega, 33.07, accuracy: 0.05)
        let start = s.state(at: 0, x0: 228, v0: 0)
        XCTAssertEqual(start.x, 228, accuracy: 1e-9)
        // Never overshoots when released from rest.
        var t = 0.0
        while t < 1 {
            XCTAssertGreaterThanOrEqual(s.state(at: t, x0: 228, v0: 0).x, -1e-9)
            t += 1.0 / 120
        }
        // Visually settled (within 0.5 pt) in roughly a quarter second for a full page.
        XCTAssertLessThan(s.settlingTime(x0: 228), 0.3)
    }

    func testUnderdampedSpringOvershoots() {
        let s = Spring(response: 0.32, dampingRatio: 0.52)  // Arc's toast pop
        var minX = 0.0
        var t = 0.0
        while t < 1 { minX = min(minX, s.state(at: t, x0: 1, v0: 0).x); t += 1.0 / 240 }
        XCTAssertLessThan(minX, -0.01)
    }

    func testOverdampedSpringSettles() {
        let s = Spring(response: 0.2, dampingRatio: 1.5)
        XCTAssertEqual(s.state(at: 2, x0: 100, v0: 0).x, 0, accuracy: 0.01)
    }

    func testVelocityMatchesDerivative() {
        for s in [Spring(response: 0.19, dampingRatio: 1), Spring(response: 0.13, dampingRatio: 0.9), Spring(response: 0.3, dampingRatio: 1.4)] {
            let h = 1e-6
            let a = s.state(at: 0.05, x0: 50, v0: -300)
            let b = s.state(at: 0.05 + h, x0: 50, v0: -300)
            XCTAssertEqual(a.v, (b.x - a.x) / h, accuracy: 0.05)
        }
    }

    func testSwipeTargetsAtMostOnePage() {
        // Slow release: nearest page.
        XCTAssertEqual(SwipePaging.targetPage(startPage: 1, position: 1.4, velocity: 0, pageWidth: 228, pageCount: 4), 1)
        XCTAssertEqual(SwipePaging.targetPage(startPage: 1, position: 1.6, velocity: 0, pageWidth: 228, pageCount: 4), 2)
        // Flick: next in its direction even from a small offset.
        XCTAssertEqual(SwipePaging.targetPage(startPage: 1, position: 1.1, velocity: 0.5, pageWidth: 228, pageCount: 4), 2)
        XCTAssertEqual(SwipePaging.targetPage(startPage: 1, position: 0.9, velocity: -0.5, pageWidth: 228, pageCount: 4), 0)
        // Flicking back returns to the start page.
        XCTAssertEqual(SwipePaging.targetPage(startPage: 1, position: 1.3, velocity: -2, pageWidth: 228, pageCount: 4), 1)
        // Never more than one page, never past the ends.
        XCTAssertEqual(SwipePaging.targetPage(startPage: 1, position: 2.9, velocity: 9, pageWidth: 228, pageCount: 4), 2)
        XCTAssertEqual(SwipePaging.targetPage(startPage: 3, position: 3.2, velocity: 3, pageWidth: 228, pageCount: 4), 3)
    }

    func testRubberBand() {
        XCTAssertEqual(SwipePaging.rubberBand(0, limit: 100), 0)
        let small = SwipePaging.rubberBand(10, limit: 100)
        let big = SwipePaging.rubberBand(1000, limit: 100)
        XCTAssertLessThan(small, 10)
        XCTAssertLessThan(big, 100)
        XCTAssertEqual(SwipePaging.rubberBand(-10, limit: 100), -small, accuracy: 1e-9)
    }

    func testColorBlend() {
        let b = SwipePaging.colorBlend(position: 1.25, pageCount: 3)
        XCTAssertEqual(b.from, 1)
        XCTAssertEqual(b.to, 2)
        XCTAssertEqual(b.t, 0.25, accuracy: 1e-9)
    }
}

final class CommandSearchTests: XCTestCase {
    let candidates: [CommandSearch.Candidate] = [
        .init(id: "t1", kind: .openTab, title: "GitHub - airc", subtitle: "github.com"),
        .init(id: "t2", kind: .openTab, title: "Inbox - Gmail", subtitle: "mail.google.com"),
        .init(id: "s1", kind: .space, title: "Work"),
        .init(id: "a1", kind: .action, title: "Pin Tab", keywords: ["bookmark"]),
        .init(id: "a2", kind: .action, title: "New Space"),
    ]

    func testPrefixBeatsSubstringBeatsSubsequence() {
        XCTAssertGreaterThan(CommandSearch.score("git", in: "GitHub")!.score, CommandSearch.score("hub", in: "GitHub")!.score)
        XCTAssertGreaterThan(CommandSearch.score("hub", in: "GitHub")!.score, CommandSearch.score("gth", in: "GitHub")!.score)
        XCTAssertNil(CommandSearch.score("xyz", in: "GitHub"))
        XCTAssertEqual(CommandSearch.score("ns", in: "New Space")?.matches, [0, 4])
    }

    /// The matching before the fold cache (folding, `hasPrefix`, `range(of:)` and `Character` arrays each call).
    private func reference(_ query: String, in text: String) -> (score: Double, matches: [Int])? {
        let q = CommandSearch.fold(query), t = CommandSearch.fold(text)
        guard !q.isEmpty else { return (0, []) }
        guard !t.isEmpty else { return nil }
        let tc = Array(t), qc = Array(q)
        if t.hasPrefix(q) { return (100 - Double(tc.count - qc.count) * 0.05, Array(0..<qc.count)) }
        var i = 0
        while i < tc.count {
            let atWordStart = i == 0 || !tc[i - 1].isLetter && !tc[i - 1].isNumber
            if atWordStart, i + qc.count <= tc.count, Array(tc[i..<(i + qc.count)]) == qc { return (80 - Double(i) * 0.1, Array(i..<(i + qc.count))) }
            i += 1
        }
        if let r = t.range(of: q) {
            let start = t.distance(from: t.startIndex, to: r.lowerBound)
            return (55 - Double(start) * 0.1, Array(start..<(start + qc.count)))
        }
        var matches: [Int] = [], qi = 0, s = 0.0, last = -2
        for (ti, ch) in tc.enumerated() where qi < qc.count && ch == qc[qi] {
            let wordStart = ti == 0 || !tc[ti - 1].isLetter && !tc[ti - 1].isNumber
            s += (ti == last + 1 ? 3 : 1) + (wordStart ? 2 : 0)
            matches.append(ti); last = ti; qi += 1
        }
        guard qi == qc.count, qc.count >= 2 else { return nil }
        return (min(40, 10 + s * 20 / Double(qc.count * 5)), matches)
    }

    func testCachedScoringMatchesTheOriginal() {
        let texts = ["GitHub - swiftlang/swift: The Swift Programming Language · GitHub", "Café Müller — Ünïcödé",
                     "ＦＵＬＬＷＩＤＴＨ ｔｅｘｔ", "Web browser - Wikipedia", "news.ycombinator.com/item?id=1",
                     "👩‍💻 Dev notes 2026", "日本語のページ", "  padded  ", "", "Straße", "a", "New Space"]
        let queries = ["git", "hub", "gth", "swift", "cafe", "muller", "unicode", "full", "wiki", "ycomb", "dev",
                       "notes", "日本", "pad", "strasse", "straße", "ns", "a", "", "xyz", "e", " git"]
        for t in texts {
            for q in queries {
                let a = CommandSearch.score(q, in: t), b = reference(q, in: t)
                XCTAssertEqual(a?.score, b?.score, "\(q) in \(t)")
                XCTAssertEqual(a?.matches, b?.matches, "\(q) in \(t)")
            }
        }
    }

    func testRanking() {
        XCTAssertEqual(CommandSearch.rank("gmail", candidates).first?.candidate.id, "t2")
        XCTAssertEqual(CommandSearch.rank("work", candidates).first?.candidate.id, "s1")
        XCTAssertEqual(CommandSearch.rank("bookm", candidates).first?.candidate.id, "a1")
        XCTAssertEqual(CommandSearch.rank("github.com", candidates).first?.candidate.id, "t1")
        XCTAssertEqual(CommandSearch.rank("", candidates).count, 5)
        XCTAssertEqual(CommandSearch.rank("é", [.init(id: "x", kind: .action, title: "Edit Theme")]).count, 1)
    }
}
