// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Whether "See what Airc sends" is open (a scripted check opens it too).
final class TelemetrySheetState: ObservableObject {
    static let shared = TelemetrySheetState()
    @Published var showingEvents = false
}

/// Settings → Privacy → "Usage data" (docs/user/telemetry.md).
struct UsageDataSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var sheet = TelemetrySheetState.shared
    @State private var resolution: TelemetryResolution = AppTelemetry.shared.resolution
    @State private var resetDone = false

    private var shared: Bool {
        switch resolution.state {
        case .sending, .recordOnly: true
        default: false
        }
    }

    /// The switch follows the person's choice; the environment, the defaults key or a build without a key override it.
    private var canChange: Bool {
        switch resolution.state {
        case .unavailable, .lockedOff: false
        default: true
        }
    }

    private var help: String {
        switch resolution.state {
        case .unavailable: "This build has no analytics key, so Airc records and sends nothing."
        case .lockedOff(.environment): "Turned off by AIRC_TELEMETRY_ENABLED in Airc's environment."
        case .lockedOff(.defaults): "Turned off by the AircTelemetryEnabled default (defaults write)."
        case .recordOnly: "A scripted run: events show below but are never sent."
        default: "Anonymous events go to PostHog in the EU, under a random ID made on this Mac: no account, no IP location, "
            + "nothing you browse, type or name."
        }
    }

    var body: some View {
        SettingsSection(title: "Usage data", help: help) {
            AircToggleRow("Share anonymous usage data", subtitle: "Which features get used, and how fast Airc is. Never what you browse.",
                          isOn: Binding(get: { shared }, set: { AppTelemetry.shared.setUserEnabled($0) }))
                .disabled(!canChange)
                .testAnchor("privacy.share")
            SettingsRow(title: "See what Airc sends", subtitle: "The last 100 events, exactly as they're sent.") {
                Button("Show…") { sheet.showingEvents = true }.buttonStyle(.airc(.secondary)).testAnchor("privacy.showEvents")
            }
            SettingsRow(title: "Anonymous ID", subtitle: resetDone ? "Reset. Nothing queued under the old ID is sent."
                            : "A random ID for this Mac, not tied to you. Reset makes a new one.") {
                Button("Reset") {
                    AppTelemetry.shared.resetInstallID()
                    resetDone = true
                }
                .buttonStyle(.airc(.plain))
                .disabled(!shared)
            }
        }
        .sheet(isPresented: $sheet.showingEvents) { TelemetryEventsSheet() }
        .onReceive(NotificationCenter.default.publisher(for: AppTelemetry.didChange)) { _ in
            resolution = AppTelemetry.shared.resolution
        }
    }
}

/// Onboarding's last step: one quiet line, where the welcome step names the licence. Only when this build shares.
struct UsageDataNote: View {
    @Environment(\.aircTheme) private var theme

    var body: some View {
        if AppTelemetry.shared.resolution.records {
            HStack(spacing: 4) {
                Text("Airc shares anonymous usage data to improve.")
                Button { (NSApp.delegate as? AppDelegate)?.showSettings(page: .privacy) } label: {
                    Text("Settings → Privacy").underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary.color)
                .testAnchor("onboarding.usageData")
            }
            .aircFont(AircFont.callout)
            .foregroundStyle(theme.textTertiary.color)
            .padding(.bottom, 26)
        }
    }
}

/// The events Airc recorded last, newest first, live.
final class TelemetryEventsModel: ObservableObject {
    @Published var records: [TelemetryRecord] = []
    private var token: Int?

    func start() {
        guard token == nil else { return }
        token = Telemetry.shared.observeRecent { [weak self] r in self?.records = r.reversed() }
    }

    func stop() {
        if let token { Telemetry.shared.removeObserver(token) }
        token = nil
    }

    deinit { stop() }
}

/// "See what Airc sends": each event as the JSON in the batch PostHog gets.
struct TelemetryEventsSheet: View {
    @StateObject private var model = TelemetryEventsModel()
    @Environment(\.aircTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var empty: String {
        switch AppTelemetry.shared.resolution.state {
        case .unavailable: "This build has no analytics key, so nothing is recorded."
        case .off, .lockedOff: "Sharing is off, so nothing is recorded."
        default: "Nothing yet. Events show here as they happen."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What Airc sends").aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
                Text("The last 100 events, newest first, exactly as they go to PostHog. Never a page, a title, a search, a name or an account.")
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 14)
            Rectangle().fill(theme.surfaceBorder.color).frame(height: 0.5)
            if model.records.isEmpty {
                Text(empty).aircFont(AircFont.body).foregroundStyle(theme.surfaceTextTertiary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.records) { r in EventCard(record: r) }
                    }
                    .padding(16)
                }
            }
            Rectangle().fill(theme.surfaceBorder.color).frame(height: 0.5)
            HStack {
                Text(model.records.count == 1 ? "1 event" : "\(model.records.count) events")
                    .aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextTertiary.color)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.airc(.primary)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 560)
        .background(theme.surface.color)
        .aircTheme(theme)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .testAnchor("privacy.eventsSheet")
    }
}

private struct EventCard: View {
    let record: TelemetryRecord
    @Environment(\.aircTheme) private var theme

    private var title: String {
        if case let .string(f)? = record.properties["feature"] { return "\(record.event) · \(f)" }
        return record.event
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).aircFont(AircFont.body).fontWeight(.semibold).foregroundStyle(theme.surfaceText.color)
                Spacer()
                Text(record.timestamp.formatted(date: .omitted, time: .standard)).aircFont(AircFont.mono)
                    .foregroundStyle(theme.surfaceTextTertiary.color)
            }
            Text(record.json).aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextSecondary.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill((theme.isDark ? AircColor.white(0.035).over(theme.surface) : AircColor.white()).color))
        .overlay(shape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
    }
}
