// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Settings → AI (docs/user/ai.md): Arc Max-style features on Apple's on-device model. Without Apple Intelligence the
/// page says what's missing and the switches are greyed out.
struct AIPage: View {
    @ObservedObject var model: SettingsModel
    @State private var availability = AIFeatures.shared.availability

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !availability.isAvailable {
                SettingsSection(title: "Apple Intelligence") {
                    SettingsRow(title: "Requires Apple Intelligence", subtitle: availability.detail) {
                        if availability == .notEnabled {
                            Button("Open System Settings…") { Self.openAppleIntelligenceSettings() }.buttonStyle(.airc(.secondary))
                        }
                    }
                    .testAnchor("ai.requires")
                }
            }
            SettingsSection(title: "Tabs",
                            help: "Names are made on this Mac by Apple's on-device model and kept only here: no title or address leaves your Mac, and private windows are never tidied. Turning this off forgets the names.") {
                AircToggleRow("Tidy tab titles",
                              subtitle: "Pinned and Today tabs with long page titles get a short name, like “Gmail Inbox”. Rest the pointer on a tab to see its full title. Tabs you renamed keep their name.",
                              isOn: Binding(get: { availability.isAvailable && model.settings.values.tidyTitles },
                                            set: { AIFeatures.shared.setTidyTitles($0, settings: model.settings) }))
                    .disabled(!availability.isAvailable)
                    .testAnchor("ai.tidyTitles")
            }
        }
        .onAppear {
            AIFeatures.shared.refreshAvailability()
            availability = AIFeatures.shared.availability
        }
        .onReceive(NotificationCenter.default.publisher(for: AIFeatures.availabilityChanged)) { _ in
            availability = AIFeatures.shared.availability
        }
    }

    /// System Settings → Apple Intelligence & Siri (only from the button: never from a scripted run).
    static func openAppleIntelligenceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
