// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Settings → AI (docs/user/ai.md): Arc Max-style features on Apple's on-device model, each off until turned on. Without
/// Apple Intelligence the page says what's missing and the switches are greyed out.
struct AIPage: View {
    @ObservedObject var model: SettingsModel
    @State private var availability = AIFeatures.shared.availability
    @Environment(\.aircTheme) private var theme

    static let privacy = "Apple Intelligence features run on this Mac. Nothing is sent anywhere."

    private func toggle(_ key: KeyPath<AppSettings.Values, Bool>, _ set: @escaping (Bool, AppSettings) -> Void) -> Binding<Bool> {
        Binding(get: { availability.isAvailable && model.settings.values[keyPath: key] },
                set: { set($0, model.settings) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                Text(Self.privacy).aircFont(AircFont.callout)
            }
            .foregroundStyle(theme.surfaceTextSecondary.color)
            .padding(.bottom, 14)
            .testAnchor("ai.privacy")
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
                              isOn: toggle(\.tidyTitles) { AIFeatures.shared.setTidyTitles($0, settings: $1) })
                    .disabled(!availability.isAvailable)
                    .testAnchor("ai.tidyTitles")
            }
            SettingsSection(title: "Pages",
                            help: "Answers and summaries come from the page's own text, read and summarized on this Mac. A link preview loads the page in the background in the same profile, as opening it would; Airc's history doesn't keep it. Private windows never use either.") {
                AircToggleRow("Ask on Page",
                              subtitle: "Ask a question about the page you're on: ⌘F, then ✦, or “Ask This Page…” in the Command Bar. The answer shows the page's sentences it's based on; click one to go there.",
                              isOn: toggle(\.askPage) { AIFeatures.shared.setAskPage($0, settings: $1) })
                    .disabled(!availability.isAvailable)
                    .testAnchor("ai.askPage")
                AircToggleRow("Link previews",
                              subtitle: "Hold ⇧ over a link, or press and hold it, for a short summary of the page it opens and its key points.",
                              isOn: toggle(\.linkPreviews) { AIFeatures.shared.setLinkPreviews($0, settings: $1) })
                    .disabled(!availability.isAvailable)
                    .testAnchor("ai.linkPreviews")
                if !model.settings.values.linkPreviewNever.isEmpty {
                    SettingsRow(title: "Never preview links on",
                                subtitle: model.settings.values.linkPreviewNever.sorted().joined(separator: ", ")) {
                        Button("Clear") { model.settings.values.linkPreviewNever = [] }.buttonStyle(.airc(.secondary))
                    }
                    .testAnchor("ai.linkPreviewNever")
                }
            }
            // P07c: Arc Max's Instant Links (CommandBar/InstantLinks.swift).
            SettingsSection(title: "Command Bar",
                            help: "Instant Links: your words go to your search engine, as a search does. Its results page loads in the background in the same profile and only its links are read, on this Mac; the model sees only their titles. Private windows never use it. Ask AI: nothing is sent until you choose the row; then the chat site opens with your prompt, like any page you open, and keeps it in your account there.") {
                // askai: the chat site the Command Bar asks, for the current Space's profile (Site Search has it per
                // profile too). It needs no Apple Intelligence.
                AskAIChoiceRow(model: model, profileID: model.store.profile(ofSpace: model.store.selectedSpace.id).id,
                               title: model.store.orderedProfiles.count > 1
                                   ? "Ask AI (\(model.store.profile(ofSpace: model.store.selectedSpace.id).name))" : "Ask AI",
                               anchor: "ai.askAI")
                AircToggleRow("Instant Links",
                              subtitle: "Type what you're looking for and press ⇧↵ to open the best result directly, or “top 3 …” for three. You see what will open first; Esc cancels.",
                              isOn: toggle(\.instantLinks) { InstantLinksFeature.set($0, settings: $1) })
                    .disabled(!availability.isAvailable)
                    .testAnchor("ai.instantLinks")
            }
            SettingsSection(title: "Downloads",
                            help: "Names come from the page a file came from and the start of its text, read on this Mac. Unless Rename automatically is on, nothing is renamed until you click Rename. Private windows' downloads are never renamed.") {
                AircToggleRow("Tidy downloads",
                              subtitle: "Finished downloads with names like “IMG_2041 (1).pdf” get a clean name, like “Lisbon itinerary.pdf”, in Library › Downloads. The file keeps its type.",
                              isOn: toggle(\.tidyDownloads) { AIFeatures.shared.setTidyDownloads($0, settings: $1) })
                    .disabled(!availability.isAvailable)
                    .testAnchor("ai.tidyDownloads")
                // tidydl: Arc's Tidy Downloads renames each download by itself, with Undo in a toast.
                AircToggleRow("Rename automatically",
                              subtitle: autoSubtitle,
                              isOn: Binding(get: { availability.isAvailable && model.settings.values.tidyDownloads && model.settings.values.tidyDownloadsAuto },
                                            set: { AIFeatures.shared.setTidyDownloadsAuto($0, settings: model.settings) }))
                    .disabled(!availability.isAvailable || !model.settings.values.tidyDownloads)
                    .testAnchor("ai.tidyDownloadsAuto")
            }
            AgentModelSection()   // agentpanel: the Airc Agent's own model (Agent/Panel/AgentModelSection.swift)
        }
        .onAppear {
            AIFeatures.shared.refreshAvailability()
            availability = AIFeatures.shared.availability
        }
        .onReceive(NotificationCenter.default.publisher(for: AIFeatures.availabilityChanged)) { _ in
            availability = AIFeatures.shared.availability
        }
    }

    /// Rename automatically's line: what it does, or why it can't be turned on now.
    private var autoSubtitle: String {
        let what = "Each finished download gets its clean name at once, and “Renamed to …” shows with Undo. Disk images, installers, apps and archives keep their names, and a file still being written or open in another app is left alone."
        if !availability.isAvailable { return "Unavailable: \(availability.detail)" }
        if !model.settings.values.tidyDownloads { return "Turn on Tidy downloads first. " + what }
        return what
    }

    /// System Settings → Apple Intelligence & Siri (only from the button: never from a scripted run).
    static func openAppleIntelligenceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
