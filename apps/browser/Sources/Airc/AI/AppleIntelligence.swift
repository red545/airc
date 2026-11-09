// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether Apple's on-device model can run here (docs/user/ai.md). Airc supports macOS 14, so the framework is
/// weak-linked: on macOS before 26 none of it loads, and every AI feature stays hidden.
enum AIAvailability: Equatable {
    case available
    /// macOS before 26, or a build without the framework.
    case needsNewerMacOS
    /// The Mac can't run Apple Intelligence.
    case deviceNotEligible
    /// Apple Intelligence is off in System Settings.
    case notEnabled
    /// Apple Intelligence is on but its model is still downloading or getting ready.
    case notReady

    var isAvailable: Bool { self == .available }

    /// Settings → AI's note under "Requires Apple Intelligence" when the features can't run.
    var detail: String {
        switch self {
        case .available: ""
        case .needsNewerMacOS: "Apple Intelligence comes with macOS 26 or later."
        case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
        case .notEnabled: "Turn it on in System Settings → Apple Intelligence & Siri."
        case .notReady: "Apple Intelligence is still getting ready on this Mac. Try again in a while."
        }
    }

    /// For logs and the scripted check.
    var label: String {
        switch self {
        case .available: "available"
        case .needsNewerMacOS: "needs macOS 26"
        case .deviceNotEligible: "device not eligible"
        case .notEnabled: "Apple Intelligence not enabled"
        case .notReady: "model not ready"
        }
    }
}

enum AppleIntelligence {
    /// Reads the system model's availability: cheap, safe on the main thread.
    static var availability: AIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .notReady
                @unknown default: return .notReady
                }
            }
        }
        #endif
        return .needsNewerMacOS
    }

    /// The on-device model behind Tidy Titles, when it can run.
    static func titleModel() -> (any TidyTitleModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available { return FoundationTitleModel() }
        #endif
        return nil
    }

    /// Loads the model's assets ahead of the first request (called once the feature is on).
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available {
            LanguageModelSession(instructions: TidyTitlePrompt.instructions).prewarm()
        }
        #endif
    }

    /// The on-device models behind Ask on Page, link previews and Tidy Downloads, when they can run.
    static func askModel() -> (any AskPageModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available { return FoundationAskModel() }
        #endif
        return nil
    }

    static func summaryModel() -> (any LinkPreviewModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available { return FoundationSummaryModel() }
        #endif
        return nil
    }

    static func fileNameModel() -> (any TidyDownloadModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available { return FoundationFileNameModel() }
        #endif
        return nil
    }

    /// The model's context window in tokens (4,096 on macOS 26), for Ask on Page's plan.
    static var contextSize: Int {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return 4096
    }

    /// Ask on Page: the instructions loaded ahead of the question (when the Ask field opens).
    static func prewarmAsk() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available {
            LanguageModelSession(instructions: AskPagePrompt.instructions).prewarm()
        }
        #endif
    }
}

#if canImport(FoundationModels)
/// Guided generation: the model fills in this one field, so the answer is a name, never a sentence about one.
@available(macOS 26.0, *)
@Generable(description: "A short name for a browser tab")
struct TidyTitleAnswer {
    @Guide(description: "The tab's new name: at most four words, from the page's title or site, with no counts or email addresses")
    var name: String
}

/// Tidy Titles on Apple's on-device model: one fresh session per page (no page's title is in another's context),
/// greedy sampling (the same title gets the same name), a few tokens at most. Runs on the Mac, never the network.
@available(macOS 26.0, *)
final class FoundationTitleModel: TidyTitleModel {
    private let model = SystemLanguageModel.default

    func shortTitle(for request: TidyTitleRequest) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: TidyTitlePrompt.instructions)
        do {
            let response = try await session.respond(to: TidyTitlePrompt.prompt(for: request), generating: TidyTitleAnswer.self,
                                                     options: aircGreedyOptions(maximumResponseTokens: 32))
            return response.content.name
        } catch let error as LanguageModelSession.GenerationError {
            // The page keeps its title; it's asked again only once its title changes.
            switch error {
            case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale, .exceededContextWindowSize: throw TidyTitleDeclined()
            default: throw error
            }
        }
    }
}

/// The model's errors that mean "won't" rather than "couldn't" (AircKit's AIRequestDeclined).
@available(macOS 26.0, *)
func declined(_ error: LanguageModelSession.GenerationError) -> Error {
    switch error {
    case .guardrailViolation: AIRequestDeclined(.guardrail)
    case .refusal: AIRequestDeclined(.refusal)
    case .unsupportedLanguageOrLocale: AIRequestDeclined(.language)
    case .exceededContextWindowSize: AIRequestDeclined(.contextTooLarge)
    default: error
    }
}

/// Ask on Page's answer: the answer first (it streams into the card), then the page's sentences behind it.
@available(macOS 26.0, *)
@Generable(description: "An answer to a question about a web page, from passages of it")
struct PageAnswerContent {
    @Guide(description: "The answer, in one to four short sentences, in the language of the question. When the passages don't answer the question, say that the page doesn't seem to say")
    var answer: String
    @Guide(description: "Up to three sentences copied word for word from the passages that show where the answer is; none when the passages don't answer the question",
           .maximumCount(3))
    var quotes: [String]
}

/// Ask on Page on Apple's on-device model: one fresh session per question (no page is in another's context), greedy
/// sampling, the answer streamed as the model writes it. Runs on the Mac, never the network. A guided answer that
/// fails to decode counts as finished only once its quotes had started (its answer was whole: AircKit's
/// AskPageRecovery); otherwise the error ends the stream and the card says the answer is unfinished.
@available(macOS 26.0, *)
final class FoundationAskModel: AskPageModel, AskPageVerifier {
    func answer(_ request: AskPageRequest) -> AsyncThrowingStream<AskPagePartial, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                let session = LanguageModelSession(model: .default, instructions: AskPagePrompt.instructions)
                var last: PageAnswerContent.PartiallyGenerated?
                do {
                    let stream = session.streamResponse(to: AskPagePrompt.prompt(for: request), generating: PageAnswerContent.self,
                                                        options: aircGreedyOptions(maximumResponseTokens: 400))
                    for try await snapshot in stream {
                        last = snapshot.content
                        c.yield(AskPagePartial(answer: snapshot.content.answer ?? "", quotes: snapshot.content.quotes ?? []))
                    }
                    c.finish()
                } catch let e as LanguageModelSession.GenerationError {
                    if case .decodingFailure = e, let kept = AskPageRecovery.partial(answer: last?.answer, quotes: last?.quotes) {
                        c.yield(kept)
                        return c.finish()
                    }
                    c.finish(throwing: declined(e))
                } catch {
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    /// The check of an answer against the page's sentences it quoted: a second, fresh session that sees only the
    /// question, the answer and those sentences, and can only say supports, contradicts or neither (guided
    /// generation), greedy, a few tokens. About 0.4 s.
    func check(_ request: AskPageCheckRequest) async throws -> AskPageEvidence {
        let session = LanguageModelSession(model: .default, instructions: AskPageCheckPrompt.instructions)
        do {
            let r = try await session.respond(to: AskPageCheckPrompt.prompt(for: request), generating: EvidenceContent.self,
                                              options: aircGreedyOptions(maximumResponseTokens: 24))
            switch r.content.verdict {
            case .supports: return .supports
            case .contradicts: return .contradicts
            case .neither: return .neither
            }
        } catch let e as LanguageModelSession.GenerationError {
            throw declined(e)
        }
    }
}

/// Ask on Page's check: one of three verdicts, nothing else.
@available(macOS 26.0, *)
@Generable(description: "Whether sentences from a web page back up an answer to a question about it")
struct EvidenceContent {
    @Guide(description: "supports if the sentences clearly say what the answer says; contradicts if they clearly say the opposite; neither if they don't settle it")
    var verdict: EvidenceVerdict
}

@available(macOS 26.0, *)
@Generable
enum EvidenceVerdict {
    case supports, contradicts, neither
}

@available(macOS 26.0, *)
@Generable(description: "A short summary of a web page")
struct LinkSummaryContent {
    @Guide(description: "Two or three short sentences: what the page is and what it says")
    var summary: String
    @Guide(description: "Up to four key points from the page, each a few words or one short sentence", .maximumCount(4))
    var keyPoints: [String]
}

/// Link previews on Apple's on-device model: a fresh session per page, greedy sampling, streamed, so that when the guided
/// answer fails to decode (the real model once left a key point open on a page of repeated paragraphs), what it had
/// finished is kept (AircKit's LinkSummaryRecovery).
@available(macOS 26.0, *)
final class FoundationSummaryModel: LinkPreviewModel {
    func summarize(_ request: LinkSummaryRequest) async throws -> LinkSummary {
        let session = LanguageModelSession(model: .default, instructions: LinkSummaryPrompt.instructions)
        var last: LinkSummaryContent.PartiallyGenerated?
        do {
            let stream = session.streamResponse(to: LinkSummaryPrompt.prompt(for: request), generating: LinkSummaryContent.self,
                                                options: aircGreedyOptions(maximumResponseTokens: 240))
            for try await snapshot in stream { last = snapshot.content }
        } catch let e as LanguageModelSession.GenerationError {
            if case .decodingFailure = e, let kept = LinkSummaryRecovery.partial(summary: last?.summary, keyPoints: last?.keyPoints) {
                return kept
            }
            throw declined(e)
        }
        guard let summary = last?.summary else { throw AIRequestDeclined(.refusal) }
        return LinkSummary(summary: summary, keyPoints: last?.keyPoints ?? [])
    }
}

@available(macOS 26.0, *)
@Generable(description: "A clean name for a downloaded file")
struct FileNameContent {
    @Guide(description: "The file's new name without its extension: at most six words, from the page or the file")
    var name: String
}

/// Tidy Downloads on Apple's on-device model: a fresh session per file, greedy sampling, a few tokens.
@available(macOS 26.0, *)
final class FoundationFileNameModel: TidyDownloadModel {
    func fileName(for request: TidyDownloadRequest) async throws -> String {
        let session = LanguageModelSession(model: .default, instructions: TidyDownloadPrompt.instructions)
        do {
            let r = try await session.respond(to: TidyDownloadPrompt.prompt(for: request), generating: FileNameContent.self,
                                              options: aircGreedyOptions(maximumResponseTokens: 40))
            return r.content.name
        } catch let e as LanguageModelSession.GenerationError {
            throw declined(e)
        }
    }
}
@available(macOS 26.0, *)
private func aircGreedyOptions(maximumResponseTokens: Int) -> GenerationOptions {
    #if compiler(>=6.4)
    GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
    #else
    GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
    #endif
}
#endif
