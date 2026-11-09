// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

/// A model that summarizes from a table (by title), records its requests, and can hang ignoring cancellation.
final class FakeSummaryModel: LinkPreviewModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [LinkSummaryRequest] = []
    var answers: [String: LinkSummary] = [:]
    var hang: Set<String> = []

    var asked: [LinkSummaryRequest] { lock.withLock { _asked } }

    func summarize(_ r: LinkSummaryRequest) async throws -> LinkSummary {
        lock.withLock { _asked.append(r) }
        if hang.contains(r.title) {
            let end = Date().addingTimeInterval(5)
            while Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        return answers[r.title] ?? LinkSummary(summary: "A page about \(r.title). It has some text.", keyPoints: ["One point"])
    }
}

func articlePage(_ title: String, url: String = "https://news.example/a") -> PageText {
    PageText(title: title, url: url, blocks: [
        PageTextBlock(index: 0, text: "Home"), PageTextBlock(index: 1, text: "About us"), PageTextBlock(index: 2, text: "Sign in"),
        PageTextBlock(index: 3, text: title, isHeading: true),
        PageTextBlock(index: 4, text: para("the harbour project", 6)),
        PageTextBlock(index: 5, text: para("the new ferry timetable", 6)),
    ])
}

final class LinkPreviewRulesTests: XCTestCase {
    let psl = PublicSuffixList(text: "com\nuk\nco.uk\nexample\n")

    func testWhichLinksGetAPreview() {
        func r(_ target: String, source: URL? = URL(string: "https://www.blog.example/post"), isPrivate: Bool = false,
               enabled: Bool = true, available: Bool = true, never: [String] = []) -> LinkPreviewPolicy.Refusal? {
            LinkPreviewPolicy.refusal(source: source, target: URL(string: target)!, isPrivate: isPrivate, enabled: enabled,
                                      available: available, never: never, suffixes: psl)
        }
        XCTAssertNil(r("https://news.example/story"))
        XCTAssertNil(r("http://127.0.0.1:8080/page.html"), "loopback pages too (the checks)")
        XCTAssertEqual(r("https://news.example/story", isPrivate: true), .privateWindow)
        XCTAssertEqual(r("https://news.example/story", enabled: false), .off)
        XCTAssertEqual(r("https://news.example/story", available: false), .unavailable)
        for t in ["mailto:someone@example.com", "javascript:void(0)", "file:///etc/hosts", "airc://settings", "data:text/html,hi"] {
            XCTAssertEqual(r(t), .notWeb, t)
        }
        // Never, by site: the link's or the page's, any subdomain.
        XCTAssertEqual(r("https://www.bank.co.uk/statements", never: ["bank.co.uk"]), .never("bank.co.uk"))
        XCTAssertEqual(r("https://news.example/story", never: ["blog.example"]), .never("blog.example"), "nothing from that site's pages")
        XCTAssertNil(r("https://other.co.uk/", never: ["bank.co.uk"]))
        XCTAssertEqual(r("https://www.blog.example/post#comments"), .samePage)
        XCTAssertEqual(LinkPreviewPolicy.site(of: URL(string: "https://a.b.example.co.uk/x")!, suffixes: psl), "example.co.uk")
        XCTAssertEqual(LinkPreviewPolicy.site(of: URL(string: "http://localhost:8080/")!, suffixes: psl), "localhost")
        XCTAssertEqual(LinkPreviewPolicy.site(of: URL(string: "http://127.0.0.1:8080/")!, suffixes: psl), "127.0.0.1", "an address is its own site")
        XCTAssertEqual(LinkPreviewPolicy.site(of: URL(string: "http://[::1]:8080/")!, suffixes: psl), "::1")
        XCTAssertNil(r("http://127.0.0.2/", source: URL(string: "http://127.0.0.1/a"), never: ["0.1"]), "never \"0.1\" isn't every address")
        XCTAssertEqual(LinkPreviewPolicy.key(URL(string: "HTTPS://News.Example/a?b=1#c")!), "https://news.example/a?b=1")
    }

    func testTheModelSeesTheStartOfTheTextWithoutMenus() throws {
        let r = try XCTUnwrap(LinkSummaryPrompt.request(for: articlePage("Harbour project opens")))
        XCTAssertEqual(r.host, "news.example")
        XCTAssertFalse(r.text.contains("Sign in"), "short pieces that aren't headings stay out")
        XCTAssertTrue(r.text.hasPrefix("Harbour project opens\n"))
        XCTAssertLessThanOrEqual(AITokens.estimate(r.text), LinkSummaryPrompt.textTokens)
        // A long page is cut to the budget.
        let long = PageText(title: "Long", url: "https://a.example/", blocks: (0..<300).map { PageTextBlock(index: $0, text: para("long \($0)", 4)) })
        let lr = try XCTUnwrap(LinkSummaryPrompt.request(for: long, maxTokens: 500))
        XCTAssertLessThanOrEqual(AITokens.estimate(lr.text), 520)
        // Too little text: no request (the card shows the title).
        XCTAssertNil(LinkSummaryPrompt.request(for: PageText(title: "Tiny", url: "", blocks: [PageTextBlock(index: 0, text: "Hello there, short page.")])))
        XCTAssertTrue(LinkSummaryPrompt.instructions.contains("two or three short sentences"))
    }

    func testAGuidedSummaryThatFailedToDecodeKeepsWhatWasFinished() throws {
        // The real model's last snapshot before its decodingFailure on the linkpreview check's article (aimax2's harness,
        // 2026-11-07): the summary whole, three points, and a fourth it never closed.
        let summary = "The page is a news article about a harbour project that will open in May. It describes the new pier and how visitors will get there by ferry or bike."
        let points = ["Harbour project opens in May.", "New pier and ferry or bike access.", "Visitors will get there by ferry or bike.",
                      "More information about the harbour and pier will be provided in the article.]}   "]
        let kept = try XCTUnwrap(LinkSummaryRecovery.partial(summary: summary, keyPoints: points))
        XCTAssertEqual(kept.summary, summary)
        XCTAssertEqual(kept.keyPoints, Array(points.prefix(3)), "the point it broke in goes")
        // Through the card's rules: shown, the title-only point out.
        let shown = try XCTUnwrap(LinkSummaryRules.accept(kept, title: "Harbour project opens in May – Example News"))
        XCTAssertEqual(shown.keyPoints, ["New pier and ferry or bike access.", "Visitors will get there by ferry or bike."])
        // A summary still being written (no key points yet), or none: nothing.
        XCTAssertNil(LinkSummaryRecovery.partial(summary: "The page is a news art", keyPoints: nil))
        XCTAssertNil(LinkSummaryRecovery.partial(summary: nil, keyPoints: []))
        XCTAssertNil(LinkSummaryRecovery.partial(summary: "  ", keyPoints: ["x"]))
        // Failing in the first point keeps the summary alone.
        XCTAssertEqual(LinkSummaryRecovery.partial(summary: summary, keyPoints: ["Harbour proj"])?.keyPoints, [])
    }

    func testTheSummaryRules() throws {
        let s = try XCTUnwrap(LinkSummaryRules.accept(LinkSummary(
            summary: "Summary: The harbour opens in May. Ferries run hourly. Tickets cost five euros. Parking is free. Bikes go free.",
            keyPoints: ["- Opens in May", "• Opens in May", "1. Ferries run hourly", "", "The harbour opens in May.",
                        "Tickets: five euros", "Parking is free", "Bikes go free", String(repeating: "very long point ", count: 20)]),
            title: "Harbour"))
        XCTAssertEqual(s.summary, "The harbour opens in May. Ferries run hourly. Tickets cost five euros.")
        // Markers out, duplicates and points that repeat a sentence of the summary out, at most four.
        XCTAssertEqual(s.keyPoints, ["Opens in May", "Tickets: five euros", "Parking is free", "Bikes go free"])
        XCTAssertNil(LinkSummaryRules.accept(LinkSummary(summary: "Harbour", keyPoints: []), title: "Harbour"))
        // A point that only repeats the page's title goes (the real model gave "Trail Runner 3" for a shop's page).
        XCTAssertEqual(LinkSummaryRules.accept(LinkSummary(summary: "A light trail running shoe with a grippy sole.",
                                                           keyPoints: ["Trail Runner 3", "Grippy sole for wet rock"]),
                                               title: "Trail Runner 3 – Example Shop")?.keyPoints, ["Grippy sole for wet rock"])
        XCTAssertNil(LinkSummaryRules.accept(LinkSummary(summary: "  ", keyPoints: ["x y z"]), title: "Harbour"))
        let long = try XCTUnwrap(LinkSummaryRules.accept(LinkSummary(summary: String(repeating: "word ", count: 200)), title: "t"))
        XCTAssertLessThanOrEqual(long.summary.count, LinkSummaryRules.summaryLength)
        XCTAssertTrue(long.summary.hasSuffix("…"))
    }
}

@MainActor
final class LinkPreviewsTests: XCTestCase {
    var fetched: [String] = []
    var pages: [String: PageText] = [:]
    var fetchDelay: TimeInterval = 0

    func center(_ model: FakeSummaryModel?) -> LinkPreviews {
        var o = LinkPreviews.Options()
        o.fetchTimeout = 0.5
        o.modelTimeout = 0.4
        o.cacheLimit = 8
        let p = LinkPreviews(options: o)
        p.model = model
        p.fetch = { [unowned self] url, profile in
            self.fetched.append(profile + " " + url.absoluteString)
            if self.fetchDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(self.fetchDelay * 1e9)) }
            return self.pages[LinkPreviewPolicy.key(url)]
        }
        return p
    }

    func states(_ p: LinkPreviews, _ url: String, profile: String = "p1") async -> [LinkPreviews.State] {
        var out: [LinkPreviews.State] = []
        let done = expectation(description: url)
        p.preview(URL(string: url)!, profileID: profile) { s in
            out.append(s)
            if s.isFinished { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 5)
        return out
    }

    func testAPreviewLoadsSummarizesAndIsKeptForTheSession() async {
        let model = FakeSummaryModel()
        model.answers["Harbour project opens"] = LinkSummary(summary: "The harbour opens in May. Ferries run hourly.", keyPoints: ["Opens in May"])
        pages["https://news.example/a"] = articlePage("Harbour project opens")
        let p = center(model)
        let s = await states(p, "https://news.example/a")
        XCTAssertEqual(s, [.loading, .summarizing(title: "Harbour project opens"),
                           .ready(title: "Harbour project opens", summary: LinkSummary(summary: "The harbour opens in May. Ferries run hourly.",
                                                                                       keyPoints: ["Opens in May"]))])
        // Again (and with a fragment): from the cache, no load, no model call.
        let again = await states(p, "https://news.example/a#top")
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(fetched, ["p1 https://news.example/a"])
        XCTAssertEqual(model.asked.count, 1)
        XCTAssertEqual(p.stats.cacheHits, 1)
        // Another profile is another session's cookies: loaded again.
        _ = await states(p, "https://news.example/a", profile: "p2")
        XCTAssertEqual(fetched.count, 2)
    }

    func testTwoAsksForOnePageShareOneLoad() async {
        pages["https://news.example/a"] = articlePage("Harbour project opens")
        fetchDelay = 0.1
        let p = center(FakeSummaryModel())
        var finished = 0
        let both = expectation(description: "both")
        both.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            p.preview(URL(string: "https://news.example/a")!, profileID: "p1") { s in
                if case .ready = s { finished += 1; both.fulfill() }
            }
        }
        await fulfillment(of: [both], timeout: 5)
        XCTAssertEqual(finished, 2)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(p.stats.joined, 1)
    }

    func testTimeoutsAndFailuresAreRetriedLater() async {
        let model = FakeSummaryModel()
        model.hang = ["Stuck page"]
        pages["https://news.example/stuck"] = articlePage("Stuck page", url: "https://news.example/stuck")
        let p = center(model)
        var clock = Date()
        p.now = { clock }
        let start = Date()
        let s = await states(p, "https://news.example/stuck")
        XCTAssertEqual(s.last, .unavailable(title: "Stuck page", .timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "a model ignoring cancellation is let go")
        XCTAssertEqual(p.stats.timeouts, 1)
        // A page that doesn't load (or loads too slowly).
        let missing = await states(p, "https://news.example/missing")
        XCTAssertEqual(missing.last, .unavailable(title: nil, .loadFailed))
        fetchDelay = 2
        let slow = await states(p, "https://news.example/slow")
        XCTAssertEqual(slow.last, .unavailable(title: nil, .loadFailed))
        fetchDelay = 0
        // A failure is kept a minute, then tried again.
        _ = await states(p, "https://news.example/missing")
        XCTAssertEqual(fetched.filter { $0.hasSuffix("/missing") }.count, 1)
        clock = clock.addingTimeInterval(61)
        _ = await states(p, "https://news.example/missing")
        XCTAssertEqual(fetched.filter { $0.hasSuffix("/missing") }.count, 2)
        // Too little text: the title, no model call.
        pages["https://news.example/tiny"] = PageText(title: "Tiny", url: "https://news.example/tiny", blocks: [PageTextBlock(index: 0, text: "Just a few words.")])
        let tiny = await states(p, "https://news.example/tiny")
        XCTAssertEqual(tiny.last, .unavailable(title: "Tiny", .tooLittleText))
        XCTAssertFalse(model.asked.contains { $0.title == "Tiny" })
    }

    func testForgetDropsPreviewsAndLateAnswers() async throws {
        pages["https://news.example/a"] = articlePage("Harbour project opens")
        fetchDelay = 0.2
        let p = center(FakeSummaryModel())
        var last: LinkPreviews.State?
        p.preview(URL(string: "https://news.example/a")!, profileID: "p1") { last = $0 }
        p.forget()
        XCTAssertEqual(last, .unavailable(title: nil, .failed), "waiting cards are told")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(p.count, 0, "the late answer isn't kept")
        XCTAssertNil(p.cached(URL(string: "https://news.example/a")!, profileID: "p1"))
        // No model: nothing is loaded.
        let none = center(nil)
        let s = await states(none, "https://news.example/a")
        XCTAssertEqual(s, [.unavailable(title: nil, .failed)])
    }

    func testAPreviewNoLongerWantedStopsItsLoadAndItsModelCall() async throws {
        final class Seen: @unchecked Sendable { var cancelled = false }
        let seen = Seen()
        let model = FakeSummaryModel()
        let p = center(model)
        p.options.fetchTimeout = 5
        p.fetch = { url, _ in
            await withTaskCancellationHandler {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return articlePage("Harbour project opens")
            } onCancel: { seen.cancelled = true }
        }
        let url = URL(string: "https://news.example/a")!
        var states: [LinkPreviews.State] = []
        p.preview(url, profileID: "p1") { states.append($0) }
        try await Task.sleep(nanoseconds: 100_000_000)
        p.stopUpdates(url, profileID: "p1")
        await eventually(1) { seen.cancelled }
        XCTAssertTrue(seen.cancelled, "the load is cancelled at once, not left to its 2-second load or 5-second timeout")
        XCTAssertEqual(p.inFlight, 0)
        XCTAssertNil(p.cached(url, profileID: "p1"), "nothing unfinished is kept")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.asked.isEmpty)
        XCTAssertEqual(states, [.loading], "the card that went away hears nothing more")
        // Asked again later: a fresh preview.
        pages["https://news.example/a"] = articlePage("Harbour project opens")
        let q = center(model)
        _ = await self.states(q, "https://news.example/a")
        XCTAssertEqual(model.asked.count, 1)
    }

    func testForgettingAProfileStopsItsWorkAndKeepsTheOthers() async throws {
        pages["https://news.example/a"] = articlePage("Harbour project opens")
        pages["https://news.example/b"] = articlePage("Ferry timetable", url: "https://news.example/b")
        let model = FakeSummaryModel()
        let p = center(model)
        _ = await states(p, "https://news.example/b", profile: "p2")
        fetchDelay = 0.2
        var told: LinkPreviews.State?
        p.preview(URL(string: "https://news.example/a")!, profileID: "p1") { told = $0 }
        p.forget(profileID: "p1")
        XCTAssertEqual(told, .unavailable(title: nil, .failed), "its card is told")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(p.cached(URL(string: "https://news.example/a")!, profileID: "p1"), "the load under way doesn't put it back")
        XCTAssertFalse(model.asked.contains { $0.title == "Harbour project opens" })
        if case .ready? = p.cached(URL(string: "https://news.example/b")!, profileID: "p2") {} else { XCTFail("another profile's preview stays") }
    }

    func testOnlyTheNewestPreviewsAreWorkedOn() async throws {
        let p = center(FakeSummaryModel())
        p.options.fetchTimeout = 5
        fetchDelay = 1
        var first: [LinkPreviews.State] = []
        p.preview(URL(string: "https://news.example/1")!, profileID: "p1") { first.append($0) }
        p.preview(URL(string: "https://news.example/2")!, profileID: "p1") { _ in }
        p.preview(URL(string: "https://news.example/3")!, profileID: "p1") { _ in }
        XCTAssertEqual(p.inFlight, 2, "at most two at once")
        XCTAssertEqual(first.last, .unavailable(title: nil, .failed), "the oldest makes way")
        p.forget()
        XCTAssertEqual(p.inFlight, 0)
    }

    func testALongTitleIsCutForThePrompt() {
        let page = PageText(title: String(repeating: "Breaking news ", count: 3000), url: "https://news.example/a",
                            blocks: articlePage("x").blocks)
        let r = LinkSummaryPrompt.request(for: page)
        XCTAssertLessThanOrEqual(AITokens.estimate(r?.title ?? ""), AskPageRequest.titleTokens)
        XCTAssertLessThanOrEqual(AITokens.estimate(LinkSummaryPrompt.prompt(for: r!)) + AITokens.estimate(LinkSummaryPrompt.instructions) + 400, 4096)
    }

    func testTheCacheIsBounded() async {
        let p = center(FakeSummaryModel())
        for i in 0..<12 {
            let u = "https://news.example/\(i)"
            pages[u] = articlePage("Page \(i)", url: u)
            _ = await states(p, u)
        }
        XCTAssertLessThanOrEqual(p.count, 8)
        XCTAssertNotNil(p.cached(URL(string: "https://news.example/11")!, profileID: "p1"))
        XCTAssertNil(p.cached(URL(string: "https://news.example/0")!, profileID: "p1"), "least recently used first")
        p.forget(profileID: "p1")
        XCTAssertEqual(p.count, 0)
    }
}
