import Foundation
import XCTest
@testable import AircKit

final class RecheckDelayedSummaryModel: LinkPreviewModel, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<LinkSummary, Never>?
    var started: Bool { lock.withLock { pending != nil } }
    func summarize(_ r: LinkSummaryRequest) async throws -> LinkSummary {
        if r.title == "OLD SECRET" {
            return await withCheckedContinuation { c in lock.withLock { pending = c } }
        }
        return LinkSummary(summary: "This is the new public summary for this page.", keyPoints: [])
    }
    func release() {
        let c = lock.withLock { let c = pending; pending = nil; return c }
        c?.resume(returning: LinkSummary(summary: "This is the old secret summary for this page.", keyPoints: []))
    }
}

@MainActor final class AIRecheckTests: XCTestCase {
    func quote(_ text: String) -> PageQuote {
        PageQuote(block: 0, start: 0, end: (text as NSString).length, text: text)
    }

    func testMissingPredicateIsNotProof() {
        let v = AskPageSupport.judge(question: "Is the hotel pool heated?", answer: "Yes.",
                                    quotes: [quote("The hotel pool closes at six.")])
        XCTAssertTrue(v.replaced, "Pool hours do not establish heating: \(v)")
    }

    func testContradictoryQuoteIsNotProof() {
        let v = AskPageSupport.judge(question: "Does the castle have a cafe?", answer: "No.",
                                    quotes: [quote("The castle has a cafe in its courtyard.")])
        XCTAssertTrue(v.replaced, "A quote explicitly contradicting No must not certify it: \(v)")
    }

    func testDisclaimerSubstringDoesNotApproveOtherClaims() {
        let v = AskPageSupport.judge(question: "Does the castle have a cafe?",
                                    answer: "No, the castle has no cafe. The page doesn't say when it opens.", quotes: [])
        XCTAssertTrue(v.replaced, "A disclaimer about hours is not a disclaimer about the cafe: \(v)")
    }

    func testNaturalFrenchQuestionAndParaphrasedDenial() {
        let v = AskPageSupport.judge(question: "Le château a-t-il un café ?", answer: "Le château ne possède aucun café.",
                                    quotes: [quote("Le château ouvre à neuf heures.")])
        XCTAssertTrue(v.replaced, "Neither question nor answer needs to begin with a listed yes/no word: \(v)")
    }

    func testAmbiguousFirstWordDoesNotChooseWrongLanguage() {
        let cases = [
            ("Is het museum open op zondag?", "Nee.", "De pagina zegt het niet."),
            ("É o museu aberto aos domingos?", "Não.", "A página não diz."),
            ("¿Existe una cafetería en el museo?", "No.", "La página no lo dice.")
        ]
        for (question, answer, expected) in cases {
            XCTAssertEqual(AskPageSupport.judge(question: question, answer: answer, quotes: []).answer, expected, question)
        }
    }

    func testSevenUnambiguousLanguagesAndPositiveEvidence() {
        let cases = [
            ("Does the castle have a cafe?", "No.", "The page doesn't say."),
            ("Hat das Schloss ein Café?", "Nein.", "Die Seite sagt dazu nichts."),
            ("Y a-t-il un café ?", "Non.", "La page ne le dit pas."),
            ("¿Hay cafetería?", "No.", "La página no lo dice."),
            ("C'è un bar?", "No.", "La pagina non lo dice."),
            ("Tem estacionamento?", "Não.", "A página não diz."),
            ("Heeft het museum een café?", "Nee.", "De pagina zegt het niet.")
        ]
        for (question, answer, expected) in cases {
            XCTAssertEqual(AskPageSupport.judge(question: question, answer: answer, quotes: []).answer, expected)
        }
        XCTAssertFalse(AskPageSupport.judge(question: "Does the castle have a cafe?", answer: "Yes.",
            quotes: [quote("The castle has a cafe in its courtyard.")]).replaced)
    }

    func testUnsupportedPoolAnswerThroughActualRun() async {
        let text = "The hotel pool closes at six. Towels are available from reception."
        let page = PageText(title: "Hotel facilities", url: "https://example.test/pool", blocks: [.init(index: 0, text: text)])
        let model = FakeAskModel(parts: [.init(answer: "Yes.", quotes: ["The hotel pool closes at six."])])
        let run = AskPageRun(question: "Is the hotel pool heated?", page: page, model: model)
        run.start()
        await eventually { run.state.isFinished }
        defer { run.cancel() }
        XCTAssertTrue(run.state.isFinished)
        XCTAssertTrue(run.state.answerReplaced, "Actual pipeline calls this done with supporting quote: \(run.state)")
    }

    func testProfileTitleFallbackSkipsForeignAndUnknownProfiles() {
        let url = "https://example.test/account"
        let pages: [TidyDownloadSources.OpenPage] = [
            .init(profileID: "personal", url: URL(string: url), title: "PERSONAL SECRET"),
            .init(profileID: nil, url: URL(string: url), title: "UNKNOWN SECRET"),
            .init(profileID: "work", url: URL(string: url), title: "")
        ]
        XCTAssertEqual(TidyDownloadSources.pageTitle(for: url, profileID: "work", openPages: pages) { _ in "WORK HISTORY" }, "WORK HISTORY")
    }

    func testLogRedactsUnknownDomainAndNestedError() {
        let marker = "SECRET-DIAGNOSIS.pdf"
        let nested = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSFilePathErrorKey: marker])
        let error = NSError(domain: marker, code: 99, userInfo: [NSLocalizedDescriptionKey: marker, NSUnderlyingErrorKey: nested])
        XCTAssertEqual(TidyDownloadRules.renameFailureLog(error), "Airc: Tidy Downloads couldn't rename a file (other 99)")
    }

    func testLateOldPreviewCannotOverwriteNewSameProfileOrOtherProfile() async {
        let links = LinkPreviews()
        links.model = FakeSummaryModel()
        var old: CheckedContinuation<PageText?, Never>?
        var version = "OLD SECRET"
        links.fetch = { _, profile in
            if profile == "p", version == "OLD SECRET" {
                return await withCheckedContinuation { old = $0 }
            }
            return articlePage(profile == "other" ? "OTHER" : version)
        }
        let url = URL(string: "https://example.test/account")!
        links.preview(url, profileID: "p") { _ in }
        await eventually { old != nil }
        XCTAssertNotNil(old)
        links.forget(profileID: "p")
        version = "NEW PUBLIC"
        links.preview(url, profileID: "p") { _ in }
        links.preview(url, profileID: "other") { _ in }
        await eventually { links.inFlight == 0 }
        old?.resume(returning: articlePage("OLD SECRET"))
        old = nil
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(links.cached(url, profileID: "p")?.title, "NEW PUBLIC")
        XCTAssertEqual(links.cached(url, profileID: "other")?.title, "OTHER")
        links.forget()
    }
    func testPurgeDuringModelCallRejectsLateSecretSummary() async {
        let model = RecheckDelayedSummaryModel()
        let links = LinkPreviews()
        links.model = model
        var title = "OLD SECRET"
        links.fetch = { _, _ in articlePage(title) }
        let url = URL(string: "https://example.test/account")!
        links.preview(url, profileID: "p") { _ in }
        await eventually { model.started }
        XCTAssertTrue(model.started)
        links.forget(profileID: "p")
        title = "NEW PUBLIC"
        links.preview(url, profileID: "p") { _ in }
        await eventually { links.inFlight == 0 }
        model.release()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(links.cached(url, profileID: "p")?.title, "NEW PUBLIC")
        links.forget()
    }

}
