// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircImport
import AircKit
import AircDesign
import SwiftUI

struct ArcExtensionRow: Codable, Identifiable {
    var profileID: String
    var extensionInfo: ImportedExtension
    /// When its Web Store page was opened from the checklist (P22); nil in checklists saved before.
    var openedAt: Date? = nil
    var id: String { profileID + ":" + extensionInfo.id }
}

/// Local-only import evidence, scoped to this Airc data directory. No sync or telemetry.
/// P22: each row is **pending** until the profile's engine has the extension, then **installed**; one whose Web Store
/// page was opened from here is **opened** (pending, the store page is where it's finished). One the Web Store doesn't
/// have (loaded unpacked, or from somewhere else) says so instead of linking. Installing them in one go needs an
/// engine API (P09b); nothing is installed automatically.
final class ArcExtensionChecklist: ObservableObject {
    static let shared = ArcExtensionChecklist()
    @Published private(set) var rows: [ArcExtensionRow] = []
    private var file: URL { AppPaths.dataDirectory.appendingPathComponent("arc-extensions.json") }
    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ArcExtensionRow].self, from: data) { rows = saved }
    }
    /// The plan's extensions replace the rows of the profiles it maps; a row importing again keeps its opened mark.
    func merge(_ plan: ImportPlan, profileIDs: [String: String]) {
        let replaced = Set(profileIDs.values)
        let opened = Dictionary(rows.compactMap { r in r.openedAt.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
        rows.removeAll { replaced.contains($0.profileID) }
        for p in plan.profiles {
            guard let pid = profileIDs[ImportAdapter.profileKey(p)] else { continue }
            rows += (plan.extensions?[p.id] ?? []).map {
                var row = ArcExtensionRow(profileID: pid, extensionInfo: $0)
                row.openedAt = opened[row.id]
                return row
            }
        }
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(rows) { try? data.write(to: file, options: .atomic) }
    }
    static func installed(_ row: ArcExtensionRow, app: AppDelegate) -> Bool {
        #if AIRC_TESTING
        if LaunchOptions.current.isAutomated, let installed = testInstalled[row.profileID] { return installed.contains(row.extensionInfo.id) }
        #endif
        guard let p = app.profiles.engineProfile(for: row.profileID) else { return false }
        return app.engine.installedExtensions(for: p).contains { $0["id"] as? String == row.extensionInfo.id }
    }

    enum State: Equatable {
        /// The profile's engine has it.
        case installed
        /// Its Web Store page was opened from the checklist; not installed yet.
        case opened
        /// Not installed, and its page not opened yet.
        case pending
        /// The Web Store doesn't have it: why, and what to do.
        case unavailable(String)
    }

    static func state(_ row: ArcExtensionRow, app: AppDelegate) -> State {
        if installed(row, app: app) { return .installed }
        switch row.extensionInfo.install {
        case .unpacked?: return .unavailable("Loaded unpacked in Arc (developer mode). Load its folder again: Manage Extensions…, Developer mode, Load unpacked.")
        case .otherSource?: return .unavailable("Not from the Chrome Web Store. Reinstall it from where you got it.")
        default: return row.openedAt == nil ? .pending : .opened
        }
    }

    /// The checklist in numbers, for its header and the checks.
    struct Counts: Equatable {
        var installed = 0, opened = 0, pending = 0, unavailable = 0
        var total: Int { installed + opened + pending + unavailable }
        /// The checklist's header: "1 of 4 reinstalled" (the rows say the rest).
        var headline: String { installed == total ? "All \(total) reinstalled" : "\(installed) of \(total) reinstalled" }
        /// "2 of 5 reinstalled · 1 opened in the Web Store · 1 to go · 1 not in the Web Store".
        var summary: String {
            var parts = ["\(installed) of \(total) reinstalled"]
            if opened > 0 { parts.append("\(opened) opened in the Web Store") }
            if pending > 0 { parts.append("\(pending) to go") }
            if unavailable > 0 { parts.append("\(unavailable) not in the Web Store") }
            return parts.joined(separator: " · ")
        }
    }

    static func counts(_ rows: [ArcExtensionRow], app: AppDelegate) -> Counts {
        rows.reduce(into: Counts()) { c, row in
            switch state(row, app: app) {
            case .installed: c.installed += 1
            case .opened: c.opened += 1
            case .pending: c.pending += 1
            case .unavailable: c.unavailable += 1
            }
        }
    }

    static func open(_ row: ArcExtensionRow, app: AppDelegate) {
        guard let space = app.store.orderedSpaces.first(where: { $0.profileID == row.profileID }) else { return }
        let c = app.controller ?? app.makeController()
        c.switchToSpace(space.id, animated: false)
        var url = row.extensionInfo.storeURL
        #if AIRC_TESTING
        if LaunchOptions.current.isAutomated, let base = testStoreBase {
            url = base.appendingPathComponent("detail/" + row.extensionInfo.id)
        }
        #endif
        c.navigate(to: url, newTab: true)
        shared.markOpened(row)
        if LaunchOptions.current.isAutomated { c.window.orderFront(nil) }
        else { c.window.makeKeyAndOrderFront(nil) }
    }

    private func markOpened(_ row: ArcExtensionRow) {
        guard let i = rows.firstIndex(where: { $0.id == row.id }), rows[i].openedAt == nil else { return }
        rows[i].openedAt = Date()
        save()
    }
    #if AIRC_TESTING
    static var testStoreBase: URL?
    static var testInstalled: [String: Set<String>] = [:]
    #endif
}

struct ArcExtensionChecklistView: View {
    @ObservedObject var checklist = ArcExtensionChecklist.shared
    var app: AppDelegate?
    var profileIDs: Set<String>? = nil
    @State private var refresh = 0
    @Environment(\.aircTheme) private var theme
    private var rows: [ArcExtensionRow] {
        checklist.rows.filter { row in
            (profileIDs?.contains(row.profileID) ?? true) && app?.store.state.profiles[row.profileID] != nil
        }
    }
    var body: some View {
        let _ = refresh
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // The count shares the title's line: onboarding's step has little height to spare for the rows.
                HStack(alignment: .firstTextBaseline) {
                    Text("Reinstall your extensions").aircFont(AircFont.title3)
                    Spacer(minLength: 8)
                    if let app {
                        Text(ArcExtensionChecklist.counts(rows, app: app).headline)
                            .aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.surfaceTextSecondary.color)
                            .lineLimit(1)
                            .testAnchor("arcimport2.summary")
                    }
                }
                Text("Choose what to bring over. Extensions are never installed automatically.")
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            let state = app.map { ArcExtensionChecklist.state(row, app: $0) } ?? .pending
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.extensionInfo.name).lineLimit(1)
                                    Text(subtitle(row, state))
                                        .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                switch state {
                                case .installed:
                                    Label("Installed", systemImage: "checkmark.circle").aircFont(AircFont.callout)
                                        .testAnchor("arcimport2.installed." + row.id)
                                case .unavailable:
                                    Label("Not in the Web Store", systemImage: "minus.circle").aircFont(AircFont.callout)
                                        .foregroundStyle(theme.surfaceTextSecondary.color)
                                        .testAnchor("arcimport2.unavailable." + row.id)
                                case .opened, .pending:
                                    Button(state == .opened ? "Open Again" : "Open in Chrome Web Store") {
                                        if let app { ArcExtensionChecklist.open(row, app: app) }
                                    }.buttonStyle(.airc(.secondary, size: .small))
                                    .testAnchor("arcimport2.store." + row.id)
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 135)
            }
            .foregroundStyle(theme.surfaceText.color)
            .testAnchor("arcimport2.checklist")
            .onAppear {
                for pid in Set(rows.map(\.profileID)) { app?.profiles.whenLoaded(pid) { _ in refresh += 1 } }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh += 1 }
        }
    }

    /// The profile, and what's left to do.
    private func subtitle(_ row: ArcExtensionRow, _ state: ArcExtensionChecklist.State) -> String {
        var parts = [app?.store.state.profiles[row.profileID]?.name ?? "Profile"]
        if !row.extensionInfo.enabled { parts.append("Disabled in Arc") }
        if row.extensionInfo.install == .managed { parts.append("Installed by your organization in Arc") }
        switch state {
        case .opened: parts.append("Opened in the Web Store: choose Add to Chrome there")
        case .unavailable(let why): parts.append(why)
        default: break
        }
        return parts.joined(separator: " · ")
    }
}
