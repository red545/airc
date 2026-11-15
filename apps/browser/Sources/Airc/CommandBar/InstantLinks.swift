// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Instant Links (P07c, Arc Max's ⇧↵; docs/user/command-bar.md): the app's side of AircKit's `InstantLinksResolver`.
/// The results page of the profile's default search loads hidden in the profile (HiddenPageReader, as a link preview
/// loads its page) and only its links are read; Apple's on-device model picks among their titles when the page doesn't
/// mark its results. On only with Settings → AI → Instant Links and Apple Intelligence (the owner's decision of
/// 2026-11-09: Airc's AI runs only on the model on the Mac). Never in a private window. The bar's side (the ⇧↵ key, the
/// "Finding…" row, the preview, Esc) is CommandBar.swift's.
struct CommandBarInstantLinks: Sendable {
    /// What the query is searched with: the profile's default (P07d), a site search included.
    var search: DefaultSearch
    var resolver: InstantLinksResolver
}

enum InstantLinksFeature {
    /// Scripted runs: the model instead of the system's (with AIFeatures' `testOverride` availability), and shorter
    /// timeouts.
    static var testModel: (any InstantLinksModel)?
    static var testOptions: InstantLinksResolver.Options?
    /// The last outcome, for the scripted checks (no query or address is logged anywhere else).
    static var lastOutcome: InstantLinksOutcome?

    /// The setting is on and Apple Intelligence can run.
    static func isOn(_ settings: AppSettings?) -> Bool {
        guard settings?.values.instantLinks == true else { return false }
        return MainActor.assumeIsolated { AIFeatures.shared.availability.isAvailable }
    }

    /// Settings → AI's switch: it turns on only with Apple Intelligence.
    static func set(_ on: Bool, settings: AppSettings) {
        settings.values.instantLinks = on && MainActor.assumeIsolated { AIFeatures.shared.availability.isAvailable }
    }

    static func context(profileID: String, search: DefaultSearch) -> CommandBarInstantLinks {
        CommandBarInstantLinks(search: search, resolver: InstantLinksResolver(fetcher: HiddenResultsFetcher(profileID: profileID),
                                                                             model: model(),
                                                                             options: testOptions ?? .init()))
    }

    static func model() -> (any InstantLinksModel)? {
        if MainActor.assumeIsolated({ AIFeatures.shared.testOverride != nil }) { return testModel }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AppleIntelligence.availability == .available { return FoundationInstantLinksModel() }
        #endif
        return nil
    }

    /// Loads `url` hidden in the profile and reads its links.
    @MainActor static func links(on url: URL, profileID: String) async throws -> [InstantLinksPageLink] {
        guard let app = NSApp.delegate as? AppDelegate, let profile = app.profiles.engineProfile(for: profileID) else {
            throw URLError(.cannotLoadFromNetwork)
        }
        let pending = PendingLoad()
        let box = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<SendableValue, Never>) in
                pending.id = HiddenPageReader.shared.evaluate(url, profile: profile, profileID: profileID,
                                                              script: InstantLinks.extractionScript) { c.resume(returning: SendableValue($0)) }
            }
        } onCancel: {
            DispatchQueue.main.async { if let id = pending.id { HiddenPageReader.shared.cancel(id) } }
        }
        guard let links = InstantLinksPageLink.parse(script: box.value) else { throw URLError(.cannotParseResponse) }
        return links
    }

    private final class PendingLoad: @unchecked Sendable { var id: Int? }
    private struct SendableValue: @unchecked Sendable {
        let value: Any?
        init(_ value: Any?) { self.value = value }
    }
}

/// The results page, read in the profile it's searched from.
struct HiddenResultsFetcher: InstantLinksFetcher {
    let profileID: String
    func links(on searchURL: URL) async throws -> [InstantLinksPageLink] {
        try await InstantLinksFeature.links(on: searchURL, profileID: profileID)
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable(description: "The links that best answer a web search")
struct InstantLinksPicks {
    @Guide(description: "The numbers of the links that best answer the search, the best first; none if none do", .maximumCount(5))
    var numbers: [Int]
}

/// The pick on Apple's on-device model: a fresh session per query, greedy, a few tokens; titles and hosts only.
@available(macOS 26.0, *)
final class FoundationInstantLinksModel: InstantLinksModel {
    func choose(_ request: InstantLinksChoiceRequest) async throws -> [Int] {
        let session = LanguageModelSession(model: .default, instructions: InstantLinksPrompt.instructions)
        #if compiler(>=6.4)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 40)
        #else
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 40)
        #endif
        do {
            let r = try await session.respond(to: InstantLinksPrompt.prompt(for: request), generating: InstantLinksPicks.self, options: options)
            return r.content.numbers
        } catch let e as LanguageModelSession.GenerationError {
            throw declined(e)
        }
    }
}
#endif

// MARK: Hosts

extension WindowController {
    /// The current Space's profile's Instant Links, when on.
    var commandBarInstantLinks: CommandBarInstantLinks? {
        guard InstantLinksFeature.isOn(app?.settings) else { return nil }
        let profile = store.profile(ofSpace: currentSpaceID)
        return InstantLinksFeature.context(profileID: profile.id, search: profile.defaultSearch)
    }

    /// The first page where ⌘T or ⌘L would open it (a new Today tab, or in place), the rest as Today tabs under it, in the
    /// preview's order.
    func openInstantLinks(_ links: [InstantLink], newTab: Bool) {
        guard let first = links.first else { return }
        // The others load when shown; until then their rows read the result's title (not google.com for a redirect).
        for l in links.dropFirst().prefix(InstantLinks.maxLinks - 1).reversed() {
            _ = try? store.openTab(url: l.url.absoluteString, inSpace: currentSpaceID, activate: false, title: l.title)
        }
        navigate(to: first.url, newTab: newTab)
    }
}
