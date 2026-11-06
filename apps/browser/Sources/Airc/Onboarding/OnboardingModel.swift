// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircImport
import AircKit
import Foundation
import SwiftUI

/// The first-run flow's steps (spec §2.13, design §7 "Onboarding window"). Logins is the Keychain explainer (2a); it
/// shares the accounts step's dot. Default browser (5) shows only while Airc isn't the default.
enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome, arc, accounts, logins, theme, defaultBrowser, done

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// 1-based dot for `AircStepIndicator` (`OnboardingModel.dots` of them).
    var dot: Int {
        switch self {
        case .welcome: 1
        case .arc: 2
        case .accounts, .logins: 3
        case .theme: 4
        case .defaultBrowser: 5
        case .done: 6
        }
    }
}

/// Everything the onboarding screens show and change. The controller does the work (discovery, import, sign-in,
/// Keychain); the views only read this and call its intents.
final class OnboardingModel: ObservableObject {
    enum ArcState: Equatable {
        case searching
        case found(version: String?)
        case notFound(String)
    }

    enum ImportState: Equatable {
        case idle
        /// The pill: a label and 0…1.
        case running(String, Double)
        case done
    }

    enum LoginsState: Equatable {
        case idle
        case reading(Double)
        case done(CredentialImport.Outcome)
        case failed(String)
        case skipped
    }

    @Published var step: OnboardingStep = .welcome
    /// +1 going forward, −1 going back (the card's slide direction).
    @Published var direction = 1
    @Published var arc: ArcState = .searching
    /// "Arc 1.171" on the found card.
    @Published var arcLabel = "Arc"
    @Published var blueprint: ImportBlueprint?
    /// The plan's warnings as a short note (IM-1).
    @Published var importNote: String?
    @Published var choosing = false
    /// Source IDs of the Spaces to import (Choose…). Everything by default.
    @Published var chosenSpaces: Set<String> = []
    @Published var includeFavorites = true
    @Published var includeLogins = true
    @Published var importState: ImportState = .idle
    @Published var result: ImportResult?
    @Published var startedFresh = false
    @Published var logins: LoginsState = .idle
    /// False on WebKit: logins come over with the Chromium engine, and nothing is read (code review H1).
    @Published var loginsAvailable = true
    /// How many Spaces of the plan the preview shows so far (they slide in one by one).
    @Published var revealedSpaces = 0
    @Published var revealedFavorites = 0
    /// Which Space the preview and the theme step show (index into `previewSpaces`).
    @Published var focusedSpace = 0
    /// The hovered profile row on the accounts step (the preview shows its profile pill).
    @Published var hoveredProfile: String?
    /// Theme changes per Space, keyed by the Space's source ID (or the Airc Space ID when starting fresh).
    @Published var themes: [String: SpaceTheme] = [:]
    @Published var translucency: AircTranslucency = .default
    /// Google account per profile source ID, once signed in.
    @Published var accounts: [String: String] = [:]
    @Published var signingIn: String?
    /// Step 5 is in the flow: Airc wasn't the default when onboarding opened (never in automated runs on the real
    /// system, where macOS is never asked).
    @Published var offersDefaultBrowser = false
    /// The macOS confirmation is up.
    @Published var askingDefault = false
    /// The browser links open in now, for the picture of the macOS dialog ("Keep “Safari”").
    var currentBrowser = "Safari"
    @Published var memberName = ""
    @Published var memberNumber = 1
    let systemDark: Bool
    let today = Date()

    // Intents, set by the controller.
    var onNext: (() -> Void)?
    var onBack: (() -> Void)?
    var onImportEverything: (() -> Void)?
    var onImportChosen: (() -> Void)?
    var onStartFresh: (() -> Void)?
    var onBackUpArc: (() -> Void)?
    var onLocateArc: (() -> Void)?
    var onSignIn: ((String) -> Void)?
    var onImportLogins: (() -> Void)?
    var onSkipLogins: (() -> Void)?
    var onThemeChange: (() -> Void)?
    var onMakeDefault: (() -> Void)?
    var onDefaultNotNow: (() -> Void)?
    var onOpen: (() -> Void)?
    var onShareCard: (() -> Void)?

    init(systemDark: Bool) {
        self.systemDark = systemDark
    }

    // MARK: Derived

    /// The step dots: five, or six with the default-browser step.
    var dots: Int { offersDefaultBrowser ? 6 : 5 }

    /// Airc profile ID → name, for the login results' rows.
    var profileNames: [String: String] {
        guard let b = blueprint, let r = result else { return [:] }
        var out: [String: String] = [:]
        for p in b.profiles { if let id = r.profileIDs[p.sourceID] { out[id] = p.name } }
        return out
    }

    var hasArc: Bool { if case .found = arc { return blueprint != nil } else { return false } }

    /// The Spaces the browser will have, in order: the plan's chosen ones, or the fresh install's one Space.
    var previewSpaces: [ImportBlueprint.Space] {
        guard let b = blueprint, !startedFresh else { return [Self.freshSpace] }
        let chosen = b.spaces.filter { chosenSpaces.contains($0.sourceID) }
        return chosen.isEmpty ? [Self.freshSpace] : chosen
    }

    static let freshSpace = ImportBlueprint.Space(sourceID: "fresh", name: "Personal", profileSourceID: "fresh")

    func theme(of space: ImportBlueprint.Space) -> SpaceTheme { themes[space.sourceID] ?? space.theme }

    func resolved(_ space: ImportBlueprint.Space) -> ResolvedTheme {
        theme(of: space).design.resolved(systemIsDark: systemDark)
    }

    var focused: ImportBlueprint.Space {
        let s = previewSpaces
        return s[min(max(0, focusedSpace), s.count - 1)]
    }

    var focusedTheme: ResolvedTheme { resolved(focused) }

    /// The profiles that come over, each with its Spaces (step 3).
    var profileRows: [(profile: ImportBlueprint.Profile, spaces: [ImportBlueprint.Space])] {
        guard let b = blueprint, !startedFresh else { return [] }
        let spaces = previewSpaces
        return b.profiles.compactMap { p in
            let mine = spaces.filter { $0.profileSourceID == p.sourceID }
            return mine.isEmpty ? nil : (p, mine)
        }
    }

    func profile(of space: ImportBlueprint.Space) -> ImportBlueprint.Profile? {
        blueprint?.profiles.first { $0.sourceID == space.profileSourceID }
    }

    func favorites(of space: ImportBlueprint.Space) -> [ImportBlueprint.Tab] {
        guard includeFavorites else { return [] }
        return Array((blueprint?.favorites[space.profileSourceID] ?? []).prefix(SpacesStore.maxFavorites))
    }

    struct Counts {
        var spaces = 0, profiles = 0, favorites = 0, tabs = 0
    }

    var counts: Counts {
        guard let b = blueprint else { return Counts() }
        let spaces = b.spaces.filter { chosenSpaces.contains($0.sourceID) }
        let profiles = Set(spaces.map(\.profileSourceID))
        let favs = profiles.reduce(0) { $0 + min(b.favorites[$1]?.count ?? 0, SpacesStore.maxFavorites) }
        let tabs = spaces.reduce(0) { $0 + $1.pinnedTabCount }
        return Counts(spaces: spaces.count, profiles: profiles.count, favorites: favs, tabs: tabs)
    }

    /// The member card's line under the name, from the choices made (Arc's card did the same).
    var memberTitle: String {
        if startedFresh { return "Curious Newcomer" }
        if choosing { return "Careful Curator" }
        if logins == .skipped { return "Methodical Guest" }
        return "Methodical Explorer"
    }

    var spaceEmojis: [String] {
        previewSpaces.compactMap(\.emoji)
    }

    var isImporting: Bool { if case .running = importState { true } else { false } }
}

extension ImportBlueprint.Space: Identifiable {
    public var id: String { sourceID }

    var emoji: String? {
        if case .emoji(let e)? = icon { return e }
        return nil
    }
}
