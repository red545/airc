// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tidy Tabs' model (docs/user/ai.md): Apple's on-device model, and only that. Owner decision 2026-11-09: without Apple
/// Intelligence there's no Tidy at all (the Today header shows no Tidy, the Command Bar no "Tidy Tabs") and no other
/// model stands in.
enum TidyTabsModels {
    /// The on-device model, when Apple Intelligence can run here now.
    static func onDevice() -> (any TidyTabsModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AppleIntelligence.availability == .available { return FoundationTabsModel() }
        #endif
        return nil
    }

    /// Loads the model's assets with Tidy's instructions (as the Tidy label shows), so the click doesn't wait for them.
    static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AppleIntelligence.availability == .available {
            LanguageModelSession(instructions: TidyTabsPrompt.instructions).prewarm()
        }
        #endif
    }
}

#if canImport(FoundationModels)
/// Guided generation: the model can only answer with folders, each a name and the numbers of its tabs.
@available(macOS 26.0, *)
@Generable(description: "Browser tabs sorted into folders by topic")
struct TabFoldersContent {
    @Guide(description: "The folders, each with at least two tabs; none when no tabs share a topic", .maximumCount(10))
    var folders: [TabFolderContent]
}

@available(macOS 26.0, *)
@Generable(description: "One folder of tabs about the same topic")
struct TabFolderContent {
    @Guide(description: "The folder's name: one to three words, like a person would label it")
    var name: String
    @Guide(description: "The numbers of the tabs in this folder, exactly as listed")
    var tabs: [Int]
}

/// Tidy Tabs on Apple's on-device model: one fresh session per part of the list (no other part's tabs in its context
/// beyond the folder names already made), greedy sampling (the same tabs get the same folders). Runs on the Mac, never
/// the network.
@available(macOS 26.0, *)
final class FoundationTabsModel: TidyTabsModel {
    func folders(for request: TidyTabsRequest) async throws -> [TidyTabsFolderAnswer] {
        let session = LanguageModelSession(model: .default, instructions: TidyTabsPrompt.instructions)
        do {
            let r = try await session.respond(to: TidyTabsPrompt.prompt(for: request), generating: TabFoldersContent.self,
                                              options: tidyTabsGreedyOptions(maximumResponseTokens: 600))
            return r.content.folders.map { TidyTabsFolderAnswer(name: $0.name, tabs: $0.tabs) }
        } catch let e as LanguageModelSession.GenerationError {
            throw declined(e)
        }
    }
}

@available(macOS 26.0, *)
private func tidyTabsGreedyOptions(maximumResponseTokens: Int) -> GenerationOptions {
    #if compiler(>=6.4)
    GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
    #else
    GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
    #endif
}
#endif
