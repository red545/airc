// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Settings → Sync (spec §2.16, docs/sync.md): the iCloud switch (off until turned on), the status, this Mac and the
/// others, and exactly what syncs and what never leaves the Mac. The first sync on a Mac that finds a sidebar in
/// iCloud asks first (SyncFirstSyncSheet).
struct SyncSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var sync = SyncCenter.shared
    @State private var syncingNow = false
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "iCloud", help: sync.isAvailable
                ? "End-to-end encrypted: the key is in your iCloud Keychain, so only your Macs can read what Airc keeps in iCloud."
                : nil) {
                AircToggleRow("Sync Spaces, pinned tabs and Favorites with iCloud",
                              subtitle: sync.isAvailable ? "Between your Macs signed in to the same Apple Account." : SyncEngine.notSetUp,
                              isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                    .disabled(!sync.isAvailable)
            }
            if sync.isAvailable, sync.isEnabled || stopped {
                SettingsSection(title: "Status", help: statusHelp) {
                    SettingsRow(title: statusTitle, subtitle: statusDetail) {
                        if sync.isEnabled {
                            Button(syncingNow ? "Syncing…" : "Sync Now") {
                                syncingNow = true
                                sync.syncNow { syncingNow = false }
                            }
                            .buttonStyle(.airc(.secondary))
                            .disabled(syncingNow || sync.firstSync != nil)
                        }
                    }
                    if let backup = sync.lastBackup {
                        SettingsRow(title: "Backup from before the first sync", subtitle: "This Mac's sidebar as it was, in Backups.") {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                                .buttonStyle(.airc(.plain))
                        }
                    }
                    ForEach(sync.devices) { d in
                        SettingsRow(title: d.isThisMac ? "\(d.name) (this Mac)" : d.name,
                                    subtitle: d.isThisMac ? nil : "Last synced " + Self.relative(d.seen)) {
                            Image(systemName: "laptopcomputer").foregroundStyle(theme.surfaceTextTertiary.color)
                        }
                    }
                }
            }
            SettingsSection(title: "What syncs") {
                SyncListRow(symbol: "square.stack", title: "Spaces", detail: "Name, icon, colour and order, and which profile each uses.")
                SyncListRow(symbol: "pin", title: "Pinned tabs and folders", detail: "Their saved addresses, names, icons and order.")
                SyncListRow(symbol: "star", title: "Favorites", detail: "Each profile's, at the top of the sidebar.")
                SyncListRow(symbol: "person.2", title: "Profile names",
                            detail: "So a Space finds its profile on your other Mac. A profile new to a Mac starts there empty.")
            }
            SettingsSection(title: "Never synced", help: "Each Mac signs in to sites in its own profiles; sync never copies logins or cookies.") {
                SyncListRow(symbol: "clock", title: "Today tabs and the Archive", detail: "What's open stays on each Mac.")
                SyncListRow(symbol: "note.text", title: "Notes", detail: "They stay on this Mac for now, pinned ones too, and what they say.")
                SyncListRow(symbol: "key", title: "History, passwords, cookies and logins", detail: nil)
                SyncListRow(symbol: "eye.slash", title: "Private windows and Little Airc", detail: nil)
                SyncListRow(symbol: "paintbrush.pointed", title: "Boosts, splits and window layout", detail: "Nor which tab or Space you're on.")
            }
        }
        .sheet(isPresented: Binding(get: { sync.firstSync != nil && model.page == .sync }, set: { _ in })) {
            if let first = sync.firstSync { SyncFirstSyncSheet(model: model, preview: first) }
        }
    }

    private var stopped: Bool { if case .stopped = sync.status { true } else { false } }

    private var statusTitle: String {
        switch sync.status {
        case .off: "Off"
        case .unavailable: "Not available"
        case .connecting: "Connecting to iCloud…"
        case .waitingForKeychain: "Waiting for iCloud Keychain"
        case .choosing: "Choose how this Mac starts"
        case .syncing: "Syncing…"
        case .upToDate: "Up to date"
        case .incomplete: "Some changes can't be read"
        case .retrying: "Not synced yet"
        case .stopped: "Sync turned off"
        }
    }

    private var statusDetail: String? {
        switch sync.status {
        case .unavailable(let why), .retrying(let why), .stopped(let why), .incomplete(let why): return why
        case .waitingForKeychain:
            return "Your other Mac's sync key comes over through iCloud Keychain. Airc checks again every minute."
        case .upToDate, .syncing:
            return sync.lastSynced.map { "Last synced " + Self.relative($0) }
        default: return nil
        }
    }

    private var statusHelp: String? {
        if case .waitingForKeychain = sync.status {
            return "Turn on iCloud Keychain on both Macs: System Settings → your name → iCloud → Passwords & Keychain (Passwords on older macOS)."
        }
        return nil
    }

    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// A row of the What syncs / Never synced lists: a symbol, a title and an optional line under it.
private struct SyncListRow: View {
    let symbol: String
    let title: String
    let detail: String?
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.surfaceTextSecondary.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                if let detail {
                    Text(detail).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
    }
}

/// The first sync on a Mac that finds another Mac's sidebar in iCloud: both sides, the profiles to match, and merge or
/// replace. A backup of this Mac's sidebar is taken first either way.
struct SyncFirstSyncSheet: View {
    @ObservedObject var model: SettingsModel
    let preview: SyncFirstSync
    @State private var choice: SyncFirstSyncChoice
    @State private var profiles: [String: SyncProfileChoice]
    @State private var working = false
    @State private var problem: String?
    @Environment(\.aircTheme) private var theme

    init(model: SettingsModel, preview: SyncFirstSync) {
        self.model = model
        self.preview = preview
        // Nothing of its own pinned yet (a new Mac): iCloud's sidebar is what it wants, if all of it can be read.
        _choice = State(initialValue: preview.complete && preview.thisMac.pinned + preview.thisMac.favorites == 0 ? .replace : .merge)
        _profiles = State(initialValue: Dictionary(uniqueKeysWithValues: preview.profiles.map { ($0.id, $0.suggestion.map(SyncProfileChoice.use) ?? .create) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your other Mac's sidebar is in iCloud").aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
                Text("Choose how this Mac starts syncing. Airc saves a backup of this Mac's sidebar first.")
                    .aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 10) {
                side("This Mac", symbol: "laptopcomputer", preview.thisMac)
                side("iCloud", symbol: "icloud", preview.iCloud)
            }
            if !preview.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Profiles from your other Mac").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                    AircGroup {
                        ForEach(preview.profiles) { p in
                            SettingsRow(title: (p.emoji.isEmpty ? "" : p.emoji + " ") + p.name,
                                        subtitle: p.spaces.isEmpty ? "Used by Favorites" : "Used by " + p.spaces.joined(separator: ", ")) {
                                AircPopUp(options: [("New profile “\(p.name)”", SyncProfileChoice.create)]
                                            + model.store.orderedProfiles.map { ("Use “\($0.name)”", SyncProfileChoice.use($0.id)) },
                                          selection: profiles[p.id] ?? .create, width: 190) { profiles[p.id] = $0 }
                            }
                        }
                    }
                    Text("A new profile starts empty: sign in to its sites on this Mac. Logins never sync.")
                        .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                    if let shared = sharedProfile {
                        Text("“\(shared)” on this Mac gets the Spaces of more than one profile from your other Mac. "
                             + "Its changes sync back as your other Mac's default profile, or the first one you chose.")
                            .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(spacing: 8) {
                option(.merge, title: "Merge with this Mac's sidebar",
                       detail: "Keeps everything from both Macs. Spaces that are on both show up twice.")
                option(.replace, title: "Replace this Mac's sidebar with iCloud's",
                       detail: preview.complete
                           ? "This Mac's Spaces, pinned tabs and Favorites are replaced; its Today tabs go to the Archive. Profiles and logins stay."
                           : "Not now: some of iCloud's sidebar can't be read on this Mac (damaged, or from a newer Airc), so it isn't complete. Merge keeps this Mac's sidebar and adds the rest when it can be read.",
                       enabled: preview.complete)
            }
            if let problem {
                Text(problem).aircFont(AircFont.callout).foregroundStyle(AircColor.destructive.color)
            }
            HStack {
                Spacer()
                Button("Cancel") { SyncCenter.shared.cancelFirstSync() }
                    .buttonStyle(.airc(.plain)).keyboardShortcut(.cancelAction).disabled(working)
                Button(working ? "Syncing…" : choice == .merge ? "Merge" : "Replace") {
                    working = true
                    problem = nil
                    SyncCenter.shared.choose(choice, profiles: profiles) { error in
                        working = false
                        if let error { problem = "Couldn't finish the first sync (\(String(describing: error))). Nothing was changed in iCloud." }
                    }
                }
                .buttonStyle(.airc(.primary)).keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(theme.surface.color)
        .aircTheme(theme)
        .interactiveDismissDisabled()
    }

    private func side(_ title: String, symbol: String, _ s: SyncFirstSync.Side) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).aircFont(AircFont.spaceName).foregroundStyle(theme.surfaceText.color)
            Text(Self.count(s.spaces.count, "Space") + " · " + Self.count(s.pinned, "pinned tab") + " · " + Self.count(s.favorites, "Favorite"))
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
            Text(s.spaces.prefix(6).joined(separator: ", ") + (s.spaces.count > 6 ? "…" : ""))
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous).fill(theme.surfaceText.alpha(0.04).color))
    }

    /// A local profile two of the other Mac's profiles would share (the default one's, or the same choice twice).
    private var sharedProfile: String? {
        var targets: [String] = preview.defaultProfile.map { [$0] } ?? []
        for p in preview.profiles { if case .use(let id)? = profiles[p.id] { targets.append(id) } }
        let twice = Dictionary(grouping: targets, by: { $0 }).first { $0.value.count > 1 }?.key
        return twice.flatMap { id in model.store.profile(id)?.name }
    }

    private func option(_ value: SyncFirstSyncChoice, title: String, detail: String, enabled: Bool = true) -> some View {
        let on = choice == value
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: on ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14)).foregroundStyle((on ? theme.accent : theme.surfaceTextTertiary).color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                Text(detail).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous)
            .fill((on ? theme.accent.alpha(0.10) : theme.surfaceText.alpha(0.03)).color))
        .overlay(RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous).inset(by: 0.25)
            .stroke((on ? theme.accent.alpha(0.5) : theme.surfaceBorder).color, lineWidth: 0.5))
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.55)
        .onTapGesture { if !working && enabled { choice = value } }
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
