import Foundation
import XCTest
@testable import AircKit

final class ReviewCancelModel: AskPageModel, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _cancelled = false
    var started: Bool { lock.withLock { _started } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    func answer(_ request: AskPageRequest) -> AsyncThrowingStream<AskPagePartial, Error> {
        lock.withLock { _started = true }
        return AsyncThrowingStream { c in
            c.onTermination = { [self] _ in lock.withLock { _cancelled = true } }
        }
    }
}

@MainActor final class AIReviewRegressionTests: XCTestCase {
    // Mirrors AskPageCard.swift's actual callback ownership; no app/UI needed.
    func testAskCardCallbackReleasesPageOnClose() {
        weak var weakRun: AskPageRun?
        do {
            let run = AskPageRun(question: "Secret question", page: lisbonPage, model: FakeAskModel(parts: []))
            weakRun = run
            run.onUpdate = { _ in _ = run.state }
            run.cancel()
        }
        XCTAssertNil(weakRun, "The production callback retains its own run and full page after cancel")
        weakRun?.onUpdate = nil // clean up this test's deliberate cycle
    }

    func testCancelReachesSuspendedModelPromptly() async throws {
        let model = ReviewCancelModel()
        var options = AskPageRun.Options()
        options.firstPartTimeout = 1
        let run = AskPageRun(question: "When?", page: lisbonPage, model: model, options: options)
        run.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.started)
        run.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(model.cancelled, "Closing the card should terminate the stream, not wait for firstPartTimeout")
        try await Task.sleep(nanoseconds: 1_100_000_000)
    }

    func testDownloadsOffClearsCapturedFileText() async {
        let downloads = TidyDownloads()
        downloads.model = FakeFileNameModel()
        downloads.isEnabled = true
        downloads.offer(key: "p/1", request: TidyDownloadPrompt.request(fileName: "document.pdf", pageTitle: "Sensitive report", pageURL: "https://example.test/report", fileText: "CONFIDENTIAL FILE EXCERPT"))
        await downloads.runQueue()
        XCTAssertEqual(downloads.asked.count, 1)
        downloads.isEnabled = false
        XCTAssertTrue(downloads.asked.isEmpty, "Production diagnostic history must not retain file excerpts after off")
    }

    func testLeavingLinkCancelsBeforeSummarizing() async throws {
        let links = LinkPreviews()
        let model = FakeSummaryModel()
        links.model = model
        links.fetch = { _, _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            return articlePage("Sensitive account")
        }
        let url = URL(string: "https://example.test/account")!
        links.preview(url, profileID: "p") { _ in }
        links.stopUpdates(url, profileID: "p")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(model.asked.count, 0, "Leaving the link should cancel unneeded inference")
    }

    func testProfileForgetCannotRepopulateFromInflightLoad() async throws {
        let links = LinkPreviews()
        links.model = FakeSummaryModel()
        links.fetch = { _, _ in
            try? await Task.sleep(nanoseconds: 150_000_000)
            return articlePage("Sensitive account")
        }
        let url = URL(string: "https://example.test/account")!
        links.preview(url, profileID: "p") { _ in }
        links.forget(profileID: "p")
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertNil(links.cached(url, profileID: "p"), "A forgotten profile's load repopulates its cache")
    }

    func testUnboundedTitleCannotOverflowAskBudget() {
        let title = String(repeating: "extraordinarily ", count: 2000)
        let page = PageText(title: title, url: lisbonPage.url, blocks: lisbonPage.blocks)
        let budget = AskPageBudget()
        let q = "When does the castle open?"
        let plan = AskPagePlanner.plan(question: q, page: page, maxTokens: budget.passageTokens(question: q))
        let request = AskPageRequest(question: q, title: page.title, host: page.host, passages: plan.passages)
        XCTAssertLessThanOrEqual(AITokens.estimate(AskPagePrompt.prompt(for: request)) + budget.fixedTokens + budget.responseTokens, budget.contextTokens)
        let summary = LinkSummaryPrompt.request(for: page)!
        XCTAssertLessThanOrEqual(AITokens.estimate(LinkSummaryPrompt.prompt(for: summary)) + 600, budget.contextTokens)
    }

    func testNoWhitespaceUnicodePassageStaysInBudget() {
        let page = PageText(title: "CJK", url: "", blocks: [PageTextBlock(index: 0, text: String(repeating: "漢", count: 5000))])
        let chunks = PageChunker.passages(page, maxTokens: 100)
        XCTAssertTrue(chunks.allSatisfy { $0.tokens <= 100 }, "Actual largest estimate: \(chunks.map(\.tokens).max() ?? 0)")
    }

    func testUnrelatedOpeningHoursDoNotGroundCafeDenial() async throws {
        let text = "The castle opens at 9:00 and closes at 21:00."
        let page = PageText(title: "Castle", url: "https://example.test/", blocks: [PageTextBlock(index: 0, text: text)])
        let model = FakeAskModel(parts: [AskPagePartial(answer: "No.", quotes: [text])])
        let run = AskPageRun(question: "Does the castle have a cafe?", page: page, model: model)
        run.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(run.state.phase, .done)
        XCTAssertEqual(run.state.answer, "The page doesn't say.")
    }

    func testPlanningAndQuoteMappingTiming() {
        let text = String(repeating: "The castle opens at nine and tickets cost fifteen euros. ", count: 3500)
        let page = PageText(title: "Large", url: "https://example.test/", blocks: [PageTextBlock(index: 0, text: text)])
        let begin = Date()
        _ = AskPagePlanner.plan(question: "How much do tickets cost?", page: page, maxTokens: 2685)
        let planned = Date()
        _ = QuoteMapper.locate(["An invented quotation with no match anywhere in this page"], in: page)
        print("REVIEW_TIMING chars=\(page.characters) plan_ms=\(planned.timeIntervalSince(begin) * 1000) quote_ms=\(Date().timeIntervalSince(planned) * 1000)")
    }
}
