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
                                                     options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32))
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
#endif
