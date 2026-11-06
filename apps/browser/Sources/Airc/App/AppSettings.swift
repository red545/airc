// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import Combine

/// App preferences that aren't part of the synced sidebar data: translucency, theme defaults, onboarding state.
/// Stored as `settings.json` next to the store, so a `--data-dir` run (and every snapshot run) has its own.
final class AppSettings: ObservableObject {
    struct Values: Codable, Equatable {
        var translucency: AircTranslucency = .default
        /// Preset id (AircDesign) new Spaces start with; nil keeps the neutral theme.
        var defaultThemePreset: String?
        var defaultAppearance: Appearance = .auto
        var onboardingStartedAt: Date?
        var onboardingCompletedAt: Date?
        /// The name on the member card.
        var memberName: String?
        /// Where `Back up now` and the daily backup go; nil = the data folder's Backups.
        var backupFolder: String?
        var suggestionsEnabled = true
        /// Settings → Privacy → "Share anonymous usage data" (docs/user/telemetry.md). On by default.
        var shareUsageData = true
        /// Profiles whose "Sign in to Google" card was dismissed.
        var dismissedSignIn: [String] = []
        /// MEM-3: a tab not seen for this long frees its page (0 = never). Default 30 minutes.
        var unloadAfterMinutes = 30
        /// Extensions shown in the URL field, per profile ID (engine/PASS7.md: pins are per profile).
        var pinnedExtensions: [String: [String]] = [:]
        /// SB-55: a playing video or a call pops out into picture in picture when you leave its tab. Every profile.
        var pipAutomatic = true
        /// SB-55: per-site exceptions, origin ("https://meet.google.com") → always (true) or never (false).
        var pipSites: [String: Bool] = [:]
        /// AT-1: Air Traffic Control's rules, in order (the first match wins), and where other links from other apps go.
        var linkRules: [LinkRule] = []
        var externalLinks: ExternalLinkTarget = .littleArc
        /// PK-1: ⇧-clicked links, and other sites a pinned tab or Favorite opens in a new tab, open in Peek.
        var peekEnabled = true
        /// Settings → Privacy → "Play DRM sites with Safari's engine" (docs/user/protected-media.md): Spotify, Netflix
        /// and the other services whose DRM needs more than Chromium's Widevine open in a WebKit page. On by default.
        var webKitProtectedMedia = true
        /// Onboarding's "Default browser" answer and the later reminder card (DefaultBrowserPrompt.swift).
        var defaultBrowser = DefaultBrowserState()
        /// Live Calendar (Calendar/CalendarCenter.swift): off until the person turns it on.
        var calendar = CalendarPreferences()

        init() {}

        // Every key is optional, so files from older builds (or newer ones) still load.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Values()
            translucency = (try? c.decodeIfPresent(AircTranslucency.self, forKey: .translucency)) ?? d.translucency
            defaultThemePreset = try? c.decodeIfPresent(String.self, forKey: .defaultThemePreset)
            defaultAppearance = (try? c.decodeIfPresent(Appearance.self, forKey: .defaultAppearance)) ?? d.defaultAppearance
            onboardingStartedAt = try? c.decodeIfPresent(Date.self, forKey: .onboardingStartedAt)
            onboardingCompletedAt = try? c.decodeIfPresent(Date.self, forKey: .onboardingCompletedAt)
            memberName = try? c.decodeIfPresent(String.self, forKey: .memberName)
            backupFolder = try? c.decodeIfPresent(String.self, forKey: .backupFolder)
            suggestionsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .suggestionsEnabled)) ?? d.suggestionsEnabled
            shareUsageData = (try? c.decodeIfPresent(Bool.self, forKey: .shareUsageData)) ?? d.shareUsageData
            dismissedSignIn = (try? c.decodeIfPresent([String].self, forKey: .dismissedSignIn)) ?? []
            unloadAfterMinutes = (try? c.decodeIfPresent(Int.self, forKey: .unloadAfterMinutes)) ?? d.unloadAfterMinutes
            pinnedExtensions = (try? c.decodeIfPresent([String: [String]].self, forKey: .pinnedExtensions)) ?? [:]
            pipAutomatic = (try? c.decodeIfPresent(Bool.self, forKey: .pipAutomatic)) ?? d.pipAutomatic
            webKitProtectedMedia = (try? c.decodeIfPresent(Bool.self, forKey: .webKitProtectedMedia)) ?? d.webKitProtectedMedia
            pipSites = (try? c.decodeIfPresent([String: Bool].self, forKey: .pipSites)) ?? [:]
            linkRules = (try? c.decodeIfPresent([LinkRule].self, forKey: .linkRules)) ?? []
            externalLinks = (try? c.decodeIfPresent(ExternalLinkTarget.self, forKey: .externalLinks)) ?? d.externalLinks
            peekEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .peekEnabled)) ?? d.peekEnabled
            defaultBrowser = (try? c.decodeIfPresent(DefaultBrowserState.self, forKey: .defaultBrowser)) ?? d.defaultBrowser
            calendar = (try? c.decodeIfPresent(CalendarPreferences.self, forKey: .calendar)) ?? d.calendar
        }
    }

    @Published var values: Values { didSet { if values != oldValue { save() } } }
    private let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: url), let v = try? Self.decoder.decode(Values.self, from: data) {
            values = v
        } else {
            values = Values()
        }
    }

    var translucency: AircTranslucency {
        get { values.translucency }
        set { values.translucency = newValue }
    }

    var defaultTheme: SpaceTheme {
        var t = values.defaultThemePreset.flatMap(DesignTheme.preset)?.model ?? .neutral
        t.appearance = values.defaultAppearance
        return t
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.encoder.encode(values).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
