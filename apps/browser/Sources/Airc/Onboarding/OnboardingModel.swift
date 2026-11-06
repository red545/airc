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
    /// What the import changes on the way (Easels left out, live folders made plain…), from the plan's warnings (IM-1).
    @Published var importChanges: [ImportAdapter.Change] = []
    /// A problem with the import itself ("The import stopped: …").
    @Published var importNote: String?
    /// A re-run into an Airc that already has Spaces: what the import does to them (merge by Arc ID).
    @Published var reimport: ReimportSummary?
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
    /// The signed-in Google account per profile source ID: from that profile's own cookies (GoogleAccountProbe) or its
    /// sign-in window. Stays on this Mac: never logged, never in telemetry.
    @Published var accounts: [String: GoogleAccount] = [:]
    /// The accounts' pictures, once loaded.
    @Published var accountPhotos: [String: CGImage] = [:]
    /// Profiles whose sign-in state is still being read.
    @Published var checkingAccounts: Set<String> = []
    @Published var signingIn: String?
    /// A re-run (ON-3) can be left from every step: the close button, ⌘W, Esc on its first step. The first run only
    /// closes by finishing (ON-5).
    @Published var closable = false
    /// Why leaving isn't possible right now (the logins are being written), or nil.
    @Published var closeBlockedReason: String?
    /// "Hold ⌘Q to Quit" is showing (a ⌘Q tap in the window).
    @Published var showsQuitHint = false
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
    /// Signed in already: sign this profile in to another Google account.
    var onSwitchAccount: ((String) -> Void)?
    var onClose: (() -> Void)?
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

    struct ProfileRow: Identifiable {
        var profile: ImportBlueprint.Profile
        var spaces: [ImportBlueprint.Space]
        var id: String { profile.sourceID }
    }

    /// The profiles that come over, each with its Spaces (step 3): one row for every profile a chosen Space uses, in
    /// the plan's order. A Space whose profile isn't in the plan's list still gets its row (ImportAdapter adds a profile
    /// for it), so the rows always match the "N profiles" count on the import step.
    var profileRows: [ProfileRow] {
        guard let b = blueprint, !startedFresh else { return [] }
        return Self.rows(b, spaces: previewSpaces)
    }

    static func rows(_ b: ImportBlueprint, spaces: [ImportBlueprint.Space]) -> [ProfileRow] {
        var rows = b.profiles.compactMap { p -> ProfileRow? in
            let mine = spaces.filter { $0.profileSourceID == p.sourceID }
            return mine.isEmpty ? nil : ProfileRow(profile: p, spaces: mine)
        }
        let known = Set(b.profiles.map(\.sourceID))
        var extra: [String] = []
        for s in spaces where !known.contains(s.profileSourceID) && !extra.contains(s.profileSourceID) { extra.append(s.profileSourceID) }
        for key in extra {
            let mine = spaces.filter { $0.profileSourceID == key }
            rows.append(ProfileRow(profile: ImportAdapter.placeholderProfile(key, spaces: mine), spaces: mine))
        }
        return rows
    }

    func profile(of space: ImportBlueprint.Space) -> ImportBlueprint.Profile? {
        blueprint?.profiles.first { $0.sourceID == space.profileSourceID }
    }

    /// A profile row was hovered (or left): the preview shows that profile's first Space with its profile pill.
    func hover(profile source: String, inside: Bool) {
        if inside {
            hoveredProfile = source
            if let i = previewSpaces.firstIndex(where: { $0.profileSourceID == source }) { focusedSpace = i }
        } else if hoveredProfile == source {
            hoveredProfile = nil
        }
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
        let profiles = Self.rows(b, spaces: spaces).map(\.profile.sourceID)
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

/// A re-run's import into an Airc that already has Spaces (IM-1: keyed on Arc's IDs). Spaces brought over before are
/// updated in place from Arc; the others are added after the user's own. Nothing the user made in Airc is removed.
struct ReimportSummary: Equatable {
    /// Chosen Spaces already in Airc from an earlier import (same Arc ID): updated in place.
    var updated = 0
    /// Chosen Spaces new to Airc: added after the user's.
    var added = 0
    /// New ones with the same name as a Space the user has (so it may look like a copy).
    var sameName = 0
    /// Spaces in Airc now (the fresh install's untouched one doesn't count).
    var existing = 0

    /// The checklist row's line ("4 already in Airc · 2 new, after yours"), or nil on a first import into an empty
    /// Airc. The step's subtitle says what that means: matched Spaces update in place, nothing is removed.
    var line: String? {
        guard existing > 0, updated + added > 0 else { return nil }
        var parts: [String] = []
        if updated > 0 { parts.append("\(updated) already in Airc") }
        if added > 0 { parts.append("\(added) new, after yours") }
        if sameName > 0 { parts.append("\(sameName) named like one of yours") }
        return parts.joined(separator: " · ")
    }
}

extension ImportBlueprint.Space: Identifiable {
    public var id: String { sourceID }

    var emoji: String? {
        if case .emoji(let e)? = icon { return e }
        return nil
    }
}
