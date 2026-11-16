// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// App settings in iCloud sync (docs/sync.md, "Settings"). Like splits, settings need no record type of their own (no
// CloudKit schema change): each synced setting is one `setting` record in the same sealed batch log, whose one field,
// `value`, holds a `SettingSyncPayload`: the setting's value as JSON and when it was changed on its Mac.
//
// - Last writer wins per setting: the later change, then the later stamp (SyncRegister.precedes). A change made while
//   sync was off counts from when it was made.
// - Only settings a person changed travel (SyncSettingsLedger). A Mac that never changed one sends nothing for it and
//   takes the synced value; a default never overwrites another Mac's choice.
// - Only settings on the allowlist (`SyncSettings.synced`) ever leave a Mac. Paths, window frames, Developer Mode,
//   hardware-specific choices, agent and MCP approvals, paired devices, tokens and passwords never do.
// - Per-profile settings carry the group's profile ID ("app.siteSearch@<profile>"); each Mac maps it to its own.
//
// Every setting operation goes in a batch of envelope version 4 (SyncEnvelope), never with sidebar operations: builds
// from before settings synced can't open those and keep them unread in their quarantine, as with notes and splits.

/// One setting's value as synced: inside a sealed batch, never on its own in iCloud.
public struct SettingSyncPayload: Codable, Hashable, Sendable {
    /// The format this build writes. A newer one is ignored here: the setting keeps its value on this Mac.
    public static let currentFormat = 1
    /// A larger value (a very long list) stays on its Mac. Far below a batch's 512 KB.
    public static let maxValueBytes = 32 * 1024

    public var format: Int
    /// The setting's value as canonical JSON (sorted keys), as the app stores it.
    public var json: String
    /// When it was changed on its Mac, in milliseconds since 1970; 0: before this Mac kept track (older builds).
    public var changed: Int64

    public init(format: Int = Self.currentFormat, json: String, changed: Int64) {
        self.format = format; self.json = json; self.changed = changed
    }

    public var isValid: Bool { format >= 1 && !json.isEmpty && json.utf8.count <= Self.maxValueBytes && changed >= 0 }
    public var isReadable: Bool { format == Self.currentFormat }
}

/// A setting's value and when it was changed (milliseconds since 1970, 0 if unknown).
public struct SyncSettingEntry: Codable, Hashable, Sendable {
    public var json: String
    public var changed: Int64
    public init(json: String, changed: Int64) { self.json = json; self.changed = changed }
}

/// The app's settings, as the engine sees them. Keys are this Mac's (a per-profile key names a local profile ID).
public struct SyncSettingsSource {
    /// Every synced setting this Mac has explicitly set, with its value and when it changed (SyncSettingsLedger).
    public var explicit: () -> [String: SyncSettingEntry]
    /// Settings from other Macs. Returns the keys it applied; a value it can't read keeps this Mac's.
    public var apply: ([String: SyncSettingEntry]) -> Set<String>

    public init(explicit: @escaping () -> [String: SyncSettingEntry], apply: @escaping ([String: SyncSettingEntry]) -> Set<String>) {
        self.explicit = explicit; self.apply = apply
    }
}

public enum SyncSettings {
    /// The envelope version for a batch of settings (SyncEnvelope).
    public static let envelopeVersion = 4

    /// Settings that sync, by key ("<base>" or "<base>@<profile>" for the per-profile ones). Everything else stays on its
    /// Mac. docs/user/sync.md lists them for people.
    public static let synced: Set<String> = [
        // Appearance
        "app.translucency", "app.defaultThemePreset", "app.defaultAppearance", "app.personalization",
        "app.tabPreviews", "app.sidebarFeedbackButton", "app.showsSpaceHeaderOnSingleUnnamed", "app.servicePreviewsOff",
        "window.sidebarOnRight",
        // Command Bar, search and Site Search
        "app.suggestionsEnabled", "app.siteSearch@", "app.askAI@", "app.instantLinks",
        "profile.searchEngine@", "profile.searchSuggestions@",
        // Shortcuts
        "app.shortcuts", "app.sidebarNavigation",
        // Links, Little Airc and Peek
        "app.linkRules", "app.externalLinks", "app.littleArcGlobal", "app.peekEnabled", "app.sharedQuotes",
        "app.dragsWindowFromPageTop", "app.pipAutomatic", "app.pipSites",
        // Archive
        "profile.archiveAfter@",
        // AI
        "app.tidyTitles", "app.askPage", "app.linkPreviews", "app.linkPreviewNever", "app.tidyDownloads", "app.tidyDownloadsAuto",
        // General, updates and What's New, notes
        "app.startupWindows", "app.restartToUpdateWhenIdle", "app.whatsNewStyle", "app.newNoteApp",
        // Privacy and blocking
        "app.shareUsageData", "app.webKitProtectedMedia", "blocking@",
    ]

    /// Settings that never leave their Mac (documented, and tests check they never travel): per-device paths and state,
    /// Developer Mode, hardware-specific choices, approvals and onboarding.
    public static let perMac: Set<String> = [
        "app.backupFolder", "app.librarySources", "app.developerAutomatic", "app.developerSites", "app.appleEventsJavaScript",
        "app.unloadAfterMinutes", "app.keepChatSitesLoaded", "app.pinnedExtensions", "app.littleArcProfiles",
        "app.defaultBrowser", "app.calendar", "app.sidebarItems", "app.dismissedSignIn", "app.memberName",
        "app.onboardingStartedAt", "app.onboardingCompletedAt", "app.showWhatsNewAfterUpdates",
    ]

    /// Whether `key` is on the allowlist (and well formed).
    public static func isSynced(_ key: String) -> Bool {
        guard isValidKey(key) else { return false }
        let (base, profile) = parts(key)
        return synced.contains(profile == nil ? base : base + "@")
    }

    /// A key's shape: short, plain characters, at most one "@" with a profile after it.
    public static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 200,
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-:@".unicodeScalars.contains($0) })
        else { return false }
        let at = key.split(separator: "@", omittingEmptySubsequences: false)
        return at.count == 1 || (at.count == 2 && !at[0].isEmpty && !at[1].isEmpty)
    }

    /// "app.siteSearch@P" → ("app.siteSearch", "P").
    public static func parts(_ key: String) -> (base: String, profile: String?) {
        guard let at = key.firstIndex(of: "@") else { return (key, nil) }
        return (String(key[..<at]), String(key[key.index(after: at)...]))
    }

    public static func key(_ base: String, profile: String?) -> String { profile.map { base + "@" + $0 } ?? base }

    /// A key with its profile mapped (`map` returns nil: the profile isn't on the other side).
    public static func mapped(_ key: String, _ map: (String) -> String?) -> String? {
        let (base, profile) = parts(key)
        guard let profile else { return key }
        return map(profile).map { Self.key(base, profile: $0) }
    }
}

/// Which of this Mac's settings the person has changed, and when: only those sync. Kept on each Mac (never synced).
///
/// `observe` takes every synced setting's current value with its default. The first time (or for a key it hasn't seen
/// yet: a new profile, an update), a value that differs from its default counts as changed "before tracking" (time 0),
/// so any later change on another Mac beats it, and a default is never sent. Afterwards, any value that differs from
/// the last one seen counts as changed now, even back to its default. A value from another Mac is `adopt`ed with that
/// Mac's time, so it isn't sent back as this Mac's change.
public struct SyncSettingsLedger: Codable, Equatable, Sendable {
    /// Every synced key's last seen value (defaults too).
    public private(set) var known: [String: String] = [:]
    /// Keys this Mac changed (or took from another Mac) → when, in ms (0: before tracking).
    public private(set) var changed: [String: Int64] = [:]

    public init() {}

    /// Returns whether anything changed (the caller saves it).
    @discardableResult
    public mutating func observe(_ current: [String: String], defaults: [String: String], now: Int64) -> Bool {
        let before = self
        for (key, value) in current {
            if let seen = known[key] {
                if seen != value { changed[key] = now }
            } else if value != defaults[key] {
                changed[key] = changed[key] ?? 0
            }
            known[key] = value
        }
        // A key that's gone (its profile was deleted) is forgotten.
        for key in known.keys where current[key] == nil { known[key] = nil; changed[key] = nil }
        return self != before
    }

    /// A value from another Mac, applied here.
    public mutating func adopt(_ key: String, _ entry: SyncSettingEntry) {
        known[key] = entry.json
        changed[key] = entry.changed
    }

    /// The settings to sync: those changed here, with their current values.
    public func explicit(_ current: [String: String]) -> [String: SyncSettingEntry] {
        var result: [String: SyncSettingEntry] = [:]
        for (key, time) in changed { if let json = current[key] { result[key] = SyncSettingEntry(json: json, changed: time) } }
        return result
    }
}

/// What the engine keeps per Mac about settings (in its state file).
struct SyncSettingsState: Codable, Equatable {
    /// "Sync settings" is off on this Mac (Settings › Sync): nothing is sent or applied; on by default with sync.
    var off = false
    /// Group key → the value this Mac last sent or applied: what it has already said or heard.
    var baseline: [String: String] = [:]
}
