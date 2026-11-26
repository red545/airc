// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Settings › Sync when the key isn't on a Mac (docs/sync.md, "Recovery key" and "Starting over"; P14b4):
/// - a Mac that syncs shows its **recovery key** (after the Mac's login), for a Mac without iCloud Keychain;
/// - a Mac waiting for the key can **type the recovery key**, or **start over with its own sidebar** when no Mac has the
///   key any more (backed up first; nothing in iCloud is deleted, and the other Macs rejoin through their first-sync
///   screen, keeping their sidebars).
enum SyncRecoverySheet: Identifiable, Equatable {
    case show(String)
    case enter
    /// "Start sync over with this Mac's sidebar?": a sheet, not an alert (a SwiftUI alert's NSAlert activates a
    /// background app, and closing one from a binding mid-layout crashed AppKit in the check).
    case startOver
    var id: String {
        switch self { case .show: "show"; case .enter: "enter"; case .startOver: "startOver" }
    }
}

/// The rows in Settings › Sync › Status, and the sheets they open.
struct SyncRecoveryRows: View {
    @ObservedObject private var sync = SyncCenter.shared

    var body: some View {
        Group {
            if sync.status == .waitingForKeychain {
                SettingsRow(title: "No iCloud Keychain on this Mac?",
                            subtitle: "Type the recovery key from a Mac that syncs: Settings › Sync › Recovery key there.") {
                    Button("Use Recovery Key…") { sync.recoverySheet = .enter }
                        .buttonStyle(.airc(.secondary))
                }
                SettingsRow(title: "Lost the key on every Mac?",
                            subtitle: "Start a new sync with this Mac's sidebar. Your other Macs keep theirs and ask to merge.") {
                    Button("Start Over…") { sync.recoverySheet = .startOver }
                        .buttonStyle(.airc(.plain))
                }
            } else if sync.hasRecoveryKey {
                SettingsRow(title: "Recovery key", subtitle: "Lets a Mac without iCloud Keychain join this sync.") {
                    Button("Show…") { sync.revealRecoveryKey { key in if let key { sync.recoverySheet = .show(key) } } }
                        .buttonStyle(.airc(.plain))
                }
            }
        }
        .sheet(item: $sync.recoverySheet) { sheet in
            switch sheet {
            case .show(let key): SyncRecoveryKeySheet(key: key)
            case .enter: SyncRecoveryEntrySheet()
            case .startOver: SyncStartOverSheet()
            }
        }
    }

    static func message(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        if error is SyncCloudFailure { return "Couldn't reach iCloud. Nothing was changed; try again." }
        return "Couldn't start over (\(String(describing: error))). Nothing was changed in iCloud."
    }
}

/// "Start sync over with this Mac's sidebar?": what happens, then Start Over (backup first) or Cancel.
struct SyncStartOverSheet: View {
    @State private var problem: String?
    @State private var working = false
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start sync over with this Mac's sidebar?").aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
                Text("Use this only if none of your Macs has the sync key any more.")
                    .aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                point("externaldrive", "Airc backs up this Mac's sidebar first, then makes a new sync with it.")
                point("icloud", "What's in iCloud now stays there, unread. Nothing is deleted.")
                point("laptopcomputer", "Your other Macs keep their sidebars. Each one asks whether to merge as soon as it has the new key, from iCloud Keychain or this Mac's recovery key.")
            }
            if let problem {
                Text(problem).aircFont(AircFont.callout).foregroundStyle(AircColor.destructive.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { SyncCenter.shared.recoverySheet = nil }
                    .buttonStyle(.airc(.plain)).keyboardShortcut(.cancelAction).disabled(working)
                Button(working ? "Starting Over…" : "Start Over") {
                    working = true
                    problem = nil
                    SyncCenter.shared.startOver { error in
                        working = false
                        if let error { problem = SyncRecoveryRows.message(error) } else { SyncCenter.shared.recoverySheet = nil }
                    }
                }
                .buttonStyle(.airc(.destructive)).disabled(working)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(theme.surface.color)
        .aircTheme(theme)
        .interactiveDismissDisabled(working)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.surfaceTextSecondary.color).frame(width: 18)
            Text(text).aircFont(AircFont.callout).foregroundStyle(theme.surfaceText.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The recovery key, 14 groups of 4, to copy or write down.
struct SyncRecoveryKeySheet: View {
    let key: String
    @State private var copied = false
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sync recovery key").aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
                Text("Type it on a Mac without iCloud Keychain: Settings › Sync › Use Recovery Key.")
                    .aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.lines(key))
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.surfaceText.color)
                .textSelection(.enabled)
                .lineSpacing(6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous).fill(theme.surfaceText.alpha(0.04).color))
                .accessibilityLabel("Recovery key")
                .accessibilityValue(key)
            Text("Anyone with this key and access to your Apple Account can read your synced sidebar. Keep it somewhere safe, like a password manager. It works until sync is started over.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    copied = true
                }
                .buttonStyle(.airc(.secondary))
                Button("Done") { SyncCenter.shared.recoverySheet = nil }
                    .buttonStyle(.airc(.primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(theme.surface.color)
        .aircTheme(theme)
    }

    /// Two lines of seven groups.
    static func lines(_ key: String) -> String {
        let groups = key.split(separator: "-")
        let half = (groups.count + 1) / 2
        return groups.prefix(half).joined(separator: " ") + "\n" + groups.dropFirst(half).joined(separator: " ")
    }
}

/// Typing the recovery key on a Mac waiting for the sync key.
struct SyncRecoveryEntrySheet: View {
    @State private var text = ""
    @State private var problem: String?
    @State private var working = false
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Use a recovery key").aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
                Text("On a Mac that syncs, open Settings › Sync › Recovery key, then type or paste it here. Capitals, spaces and dashes don't matter.")
                    .aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AircTextField(text: $text, placeholder: "XXXX-XXXX-XXXX-…", message: problem, isError: problem != nil)
                .onSubmit(use)
            HStack {
                Spacer()
                Button("Cancel") { SyncCenter.shared.recoverySheet = nil }
                    .buttonStyle(.airc(.plain)).keyboardShortcut(.cancelAction).disabled(working)
                Button(working ? "Checking…" : "Continue", action: use)
                    .buttonStyle(.airc(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(theme.surface.color)
        .aircTheme(theme)
        .interactiveDismissDisabled(working)
    }

    private func use() {
        guard !working else { return }
        working = true
        problem = nil
        SyncCenter.shared.useRecoveryKey(text) { error in
            working = false
            if let error { problem = SyncRecoveryRows.message(error) } else { SyncCenter.shared.recoverySheet = nil }
        }
    }
}
