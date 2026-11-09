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
        /// DEV-1, Arc's Developer Mode: on by itself for localhost (Settings → General), and per site (Site Controls, ⌃D;
        /// AircKit's DeveloperSitePolicy). The opt-in `developerMode` of 2026-11-07 isn't read any more.
        var developerAutomatic = true
        var developerSites = DeveloperSitePolicy()
        /// K07, Arc's View › Allow JavaScript from Apple Events (Scripting/): off until turned on, for every profile.
        var appleEventsJavaScript = false
        /// Settings → Privacy → "Share anonymous usage data" (docs/user/telemetry.md). On by default.
        var shareUsageData = true
        /// Profiles whose "Sign in to Google" card was dismissed.
        var dismissedSignIn: [String] = []
        /// MEM-3: a tab not seen for this long frees its page (0 = never). Default 30 minutes.
        var unloadAfterMinutes = 30
        /// MEM-3: pinned tabs and Favorites of chat, mail and calendar sites (AircKit's KeepLoadedSites) never unload.
        var keepChatSitesLoaded = true
        /// Extensions shown in the URL field, per profile ID (engine/PASS7.md: pins are per profile).
        var pinnedExtensions: [String: [String]] = [:]
        /// SB-55: a playing video or a call pops out into picture in picture when you leave its tab. Every profile.
        var pipAutomatic = true
        /// SB-55: per-site exceptions, origin ("https://meet.google.com") → always (true) or never (false).
        var pipSites: [String: Bool] = [:]
        /// AT-1: Air Traffic Control's rules, in order (the first match wins), and where other links from other apps go.
        var linkRules: [LinkRule] = []
        var littleArcProfiles = LittleArcProfiles()
        var externalLinks: ExternalLinkTarget = .littleArc
        /// P06b: Little Arc from any app, looking up the selection, the archive interval (Browser/LittleArcGlobalActions.swift).
        var littleArcGlobal = LittleArcGlobalSettings()
        /// W07: Arc's "Allow window dragging from the top of webpages", on by default (Browser/PageDrag.swift).
        var dragsWindowFromPageTop = true
        /// P01c: Arc's showSpaceHeaderOnSingleUnnamedSpaces (the Space menu's Show / Hide Space Header).
        var showsSpaceHeaderOnSingleUnnamed = false
        /// P01c: Arc's shareQuoteLinkEnabled ("Enable Shared Quotes when highlighting text."), on by default.
        var sharedQuotes = true
        /// PK-1: ⇧-clicked links, and other sites a pinned tab or Favorite opens in a new tab, open in Peek.
        var peekEnabled = true
        /// SB-45: a card with the page's picture beside a sidebar tab under the pointer (Settings → Appearance).
        var tabPreviews = true
        /// Settings → AI → "Tidy tab titles" (AI/AIFeatures.swift, docs/user/ai.md): off until the person turns it on.
        var tidyTitles = false
        /// Settings → AI → "Ask on Page" (AI/AskPageCard.swift): off until turned on.
        var askPage = false
        /// Settings → AI → "Link previews" (AI/LinkPreviewCard.swift): off until turned on. Sites (registrable domains,
        /// "example.co.uk") whose links, and whose pages' links, never get a preview.
        var linkPreviews = false
        var linkPreviewNever: [String] = []
        /// Settings → AI → "Tidy downloads" (AI/TidyDownloadsFeature.swift): off until turned on.
        var tidyDownloads = false
        /// Settings → Privacy → "Play DRM sites with Safari's engine" (docs/user/protected-media.md): Spotify, Netflix
        /// and the other services whose DRM needs more than Chromium's Widevine open in a WebKit page. On by default.
        var webKitProtectedMedia = true
        /// Onboarding's "Default browser" answer and the later reminder card (DefaultBrowserPrompt.swift).
        var defaultBrowser = DefaultBrowserState()
        /// Live Calendar (Calendar/CalendarCenter.swift): off until the person turns it on.
        var calendar = CalendarPreferences()
        /// Library › Media's sources (P10a): Captures, downloads, and the folders the person let it show.
        var librarySources = LibrarySourceSettings()
        /// Settings → Shortcuts' sidebar keys (K02, W03): Favorites in ⌘1–9, ⌘9 the ninth or the last item, ⌥ shows a
        /// hidden sidebar (App/ShortcutCenter.swift).
        var sidebarNavigation = SidebarNavigationPreferences()
        /// Settings → Shortcuts (CB-4): command id → the user's key ("alt+cmd+l"), "" for none. Only changes are kept;
        /// the defaults are Commands.swift's table (App/ShortcutCenter.swift).
        var shortcuts: [String: String] = [:]
        /// The tab menus' per-row switches (S03): a Favorite's "Show Unread Badge" (AircKit's SidebarItemPreferences).
        var sidebarItems = SidebarItemPreferences()
        /// Settings › Appearance › App Icon, General › Sounds and Haptics (Settings/AppPersonalization.swift).
        var personalization = PersonalizationPreferences()
        /// Settings › General › Automatic Updates, Arc's "Automatically update my Arc" (off, as Arc's): a downloaded update
        /// restarts Airc by itself once you've been away a while and nothing would be interrupted (Browser/UpdateButton.swift).
        var restartToUpdateWhenIdle = false
        /// Settings → Site Search: each profile's sites for the Command Bar's Site Search (AircKit's SiteSearchSettings).
        var siteSearch = SiteSearchSettings()

        /// Settings → General → Notes: what New Note makes (Notes/NoteExport.swift, AircKit's NoteApp). Airc's own notes
        /// unless the person chooses another app; a value from a newer build reads as Airc's.
        var newNoteApp: NoteApp = .airc

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
            developerAutomatic = (try? c.decodeIfPresent(Bool.self, forKey: .developerAutomatic)) ?? d.developerAutomatic
            developerSites = (try? c.decodeIfPresent(DeveloperSitePolicy.self, forKey: .developerSites)) ?? d.developerSites
            appleEventsJavaScript = (try? c.decodeIfPresent(Bool.self, forKey: .appleEventsJavaScript)) ?? false
            shareUsageData = (try? c.decodeIfPresent(Bool.self, forKey: .shareUsageData)) ?? d.shareUsageData
            dismissedSignIn = (try? c.decodeIfPresent([String].self, forKey: .dismissedSignIn)) ?? []
            unloadAfterMinutes = (try? c.decodeIfPresent(Int.self, forKey: .unloadAfterMinutes)) ?? d.unloadAfterMinutes
            keepChatSitesLoaded = (try? c.decodeIfPresent(Bool.self, forKey: .keepChatSitesLoaded)) ?? d.keepChatSitesLoaded
            pinnedExtensions = (try? c.decodeIfPresent([String: [String]].self, forKey: .pinnedExtensions)) ?? [:]
            pipAutomatic = (try? c.decodeIfPresent(Bool.self, forKey: .pipAutomatic)) ?? d.pipAutomatic
            webKitProtectedMedia = (try? c.decodeIfPresent(Bool.self, forKey: .webKitProtectedMedia)) ?? d.webKitProtectedMedia
            pipSites = (try? c.decodeIfPresent([String: Bool].self, forKey: .pipSites)) ?? [:]
            linkRules = (try? c.decodeIfPresent([LinkRule].self, forKey: .linkRules)) ?? []
            littleArcProfiles = (try? c.decodeIfPresent(LittleArcProfiles.self, forKey: .littleArcProfiles)) ?? LittleArcProfiles()
            externalLinks = (try? c.decodeIfPresent(ExternalLinkTarget.self, forKey: .externalLinks)) ?? d.externalLinks
            littleArcGlobal = (try? c.decodeIfPresent(LittleArcGlobalSettings.self, forKey: .littleArcGlobal)) ?? d.littleArcGlobal
            dragsWindowFromPageTop = (try? c.decodeIfPresent(Bool.self, forKey: .dragsWindowFromPageTop)) ?? d.dragsWindowFromPageTop
            showsSpaceHeaderOnSingleUnnamed = (try? c.decodeIfPresent(Bool.self, forKey: .showsSpaceHeaderOnSingleUnnamed)) ?? d.showsSpaceHeaderOnSingleUnnamed
            sharedQuotes = (try? c.decodeIfPresent(Bool.self, forKey: .sharedQuotes)) ?? d.sharedQuotes
            peekEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .peekEnabled)) ?? d.peekEnabled
            tabPreviews = (try? c.decodeIfPresent(Bool.self, forKey: .tabPreviews)) ?? d.tabPreviews
            tidyTitles = (try? c.decodeIfPresent(Bool.self, forKey: .tidyTitles)) ?? d.tidyTitles
            askPage = (try? c.decodeIfPresent(Bool.self, forKey: .askPage)) ?? d.askPage
            linkPreviews = (try? c.decodeIfPresent(Bool.self, forKey: .linkPreviews)) ?? d.linkPreviews
            linkPreviewNever = (try? c.decodeIfPresent([String].self, forKey: .linkPreviewNever)) ?? []
            tidyDownloads = (try? c.decodeIfPresent(Bool.self, forKey: .tidyDownloads)) ?? d.tidyDownloads
            defaultBrowser = (try? c.decodeIfPresent(DefaultBrowserState.self, forKey: .defaultBrowser)) ?? d.defaultBrowser
            calendar = (try? c.decodeIfPresent(CalendarPreferences.self, forKey: .calendar)) ?? d.calendar
            librarySources = (try? c.decodeIfPresent(LibrarySourceSettings.self, forKey: .librarySources)) ?? d.librarySources
            sidebarNavigation = (try? c.decodeIfPresent(SidebarNavigationPreferences.self, forKey: .sidebarNavigation)) ?? d.sidebarNavigation
            shortcuts = (try? c.decodeIfPresent([String: String].self, forKey: .shortcuts)) ?? [:]
            sidebarItems = (try? c.decodeIfPresent(SidebarItemPreferences.self, forKey: .sidebarItems)) ?? d.sidebarItems
            personalization = (try? c.decodeIfPresent(PersonalizationPreferences.self, forKey: .personalization)) ?? d.personalization
            restartToUpdateWhenIdle = (try? c.decodeIfPresent(Bool.self, forKey: .restartToUpdateWhenIdle)) ?? d.restartToUpdateWhenIdle
            siteSearch = (try? c.decodeIfPresent(SiteSearchSettings.self, forKey: .siteSearch)) ?? d.siteSearch
            newNoteApp = (try? c.decodeIfPresent(NoteApp.self, forKey: .newNoteApp)) ?? d.newNoteApp
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
