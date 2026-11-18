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
/// have (loaded unpacked, or from somewhere else) says so instead of linking. Install all requests each row in its
/// original destination profile, with Chromium permission review for every new installation.
final class ArcExtensionChecklist: ObservableObject {
    static let shared = ArcExtensionChecklist()
    @Published private(set) var rows: [ArcExtensionRow] = []
    private var file: URL { AppPaths.dataDirectory.appendingPathComponent("arc-extensions.json") }
    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ArcExtensionRow].self, from: data) { rows = saved }
    }
    /// The plan's extensions replace the rows of the profiles it maps; a row importing again keeps its opened mark.
    /// `key`: a plan profile's source key in `profileIDs` (Arc's "arc-profile:<dir>"; diaimport: a browser read's own
    /// IDs, "dia-profile:<dir>").
    func merge(_ plan: ImportPlan, profileIDs: [String: String], key: (ImportedProfile) -> String = ImportAdapter.profileKey) {
        let replaced = Set(profileIDs.values)
        let opened = Dictionary(rows.compactMap { r in r.openedAt.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
        rows.removeAll { replaced.contains($0.profileID) }
        for p in plan.profiles {
            guard let pid = profileIDs[key(p)] else { continue }
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
    /// Shows other rows without saving them (arcimport2's long list); the saved file stays as it was.
    func testShow(_ shown: [ArcExtensionRow]) { rows = shown }
    #endif
}

struct ArcExtensionChecklistView: View {
    @ObservedObject var checklist = ArcExtensionChecklist.shared
    var app: AppDelegate?
    var profileIDs: Set<String>? = nil
    /// Onboarding's fixed 760×540 card (ON-5) has no height to spare: the title, the count and Install all share one
    /// line, the line under it is left out, and the list shows two rows. Settings has room for four and the line.
    var compact = false
    @State private var refresh = 0
    @State private var installing = false
    @State private var outcomes: [ExtensionProfileResult] = []
    @State private var rowHeights: [String: CGFloat] = [:]
    @State private var listContent = CGRect.zero
    @Environment(\.aircTheme) private var theme

    static let rowSpacing: CGFloat = 8
    /// A row before it's measured: the name's line and the caption's.
    static let rowEstimate: CGFloat = 34
    /// How much of the next row shows under the last whole one when there are more, under the fade: the list says it
    /// scrolls (importcard).
    static let peek: CGFloat = 18
    private var visibleRows: Int { compact ? 2 : 4 }

    private var rows: [ArcExtensionRow] {
        checklist.rows.filter { row in
            (profileIDs?.contains(row.profileID) ?? true) && app?.store.state.profiles[row.profileID] != nil
        }
    }
    private var overflows: Bool { rows.count > visibleRows }
    /// Whole rows up to `visibleRows`, then a peek of the next. Measured, so a caption that wraps never clips a button.
    private var listHeight: CGFloat {
        let shown = rows.prefix(visibleRows)
        let h = shown.reduce(0) { $0 + (rowHeights[$1.id] ?? Self.rowEstimate) } + CGFloat(max(0, shown.count - 1)) * Self.rowSpacing
        return overflows ? h + Self.rowSpacing + Self.peek : h
    }
    /// Rows below the visible part: the bottom fades, as the accounts list above does.
    private var moreBelow: Bool { overflows && listContent.maxY > listHeight + 1 }

    var body: some View {
        let _ = refresh
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Reinstall your extensions").aircFont(AircFont.title3).lineLimit(1)
                        .help("Choose what to bring over. Extensions are never installed automatically.")
                    Spacer(minLength: 8)
                    if let app {
                        Text(ArcExtensionChecklist.counts(rows, app: app).headline)
                            .aircFont(AircFont.callout.weight(.medium)).foregroundStyle(theme.surfaceTextSecondary.color)
                            .lineLimit(1).fixedSize()
                            .testAnchor("arcimport2.summary")
                    }
                    Button(installing ? "Installing…" : "Install all", action: installAll)
                        .buttonStyle(.airc(.secondary, size: .small)).disabled(installing || app == nil)
                        .fixedSize()
                        .help("Each extension asks for its permissions in its own profile first.")
                        .testAnchor("arcimport2.install-all")
                }
                if !compact {
                    Text("Choose what to bring over. Extensions are never installed automatically.")
                        .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                }
                list
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

    /// Every row, scrolling past `visibleRows` with its scroller shown and the bottom faded.
    private var list: some View {
        ScrollView(.vertical, showsIndicators: overflows) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(rows) { row in
                    rowView(row)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeights[row.id] = $0 }
                }
            }
            .padding(.trailing, overflows ? 12 : 0)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("arcimport2.list")) }) { listContent = $0 }
        }
        .coordinateSpace(name: "arcimport2.list")
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: listHeight)
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(moreBelow ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.peek)
            }
        }
        .modifier(FlashScrollerOnAppear(enabled: overflows))
        .testAnchor("arcimport2.list")
    }

    private func rowView(_ row: ArcExtensionRow) -> some View {
        let state = app.map { ArcExtensionChecklist.state(row, app: $0) } ?? .pending
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.extensionInfo.name).aircFont(AircFont.body).lineLimit(1)
                Text(subtitle(row, state))
                    .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch state {
            case .installed:
                Label("Installed", systemImage: "checkmark.circle").aircFont(AircFont.callout).fixedSize()
                    .testAnchor("arcimport2.installed." + row.id)
            case .unavailable:
                Label("Not in the Web Store", systemImage: "minus.circle").aircFont(AircFont.callout).fixedSize()
                    .foregroundStyle(theme.surfaceTextSecondary.color)
                    .testAnchor("arcimport2.unavailable." + row.id)
            case .opened, .pending:
                Button(state == .opened ? "Open Again" : "Open in Chrome Web Store") {
                    if let app { ArcExtensionChecklist.open(row, app: app) }
                }.buttonStyle(.airc(.secondary, size: .small)).fixedSize()
                .testAnchor("arcimport2.store." + row.id)
            }
        }
        .frame(minHeight: Self.rowEstimate)
        .testAnchor("arcimport2.row." + row.id)
    }

    private func installAll() {
        guard let app else { return }
        installing = true
        let requests = rows.filter {
            if case .unavailable = ArcExtensionChecklist.state($0, app: app) { return false }
            return true
        }.map { ($0.extensionInfo.id, $0.profileID) }
        (app.controller ?? app.makeController()).installExtensions(requests) {
            outcomes = $0; installing = false; refresh += 1
        }
    }

    /// What Install all said for this row, shown in its caption (the step has no room for a list of results).
    private func outcome(_ row: ArcExtensionRow) -> String? {
        outcomes.first { $0.profileID == row.profileID && $0.extensionID == row.extensionInfo.id }?.message
    }

    /// The profile, and what's left to do.
    private func subtitle(_ row: ArcExtensionRow, _ state: ArcExtensionChecklist.State) -> String {
        var parts = [app?.store.state.profiles[row.profileID]?.name ?? "Profile"]
        if !row.extensionInfo.enabled { parts.append("Disabled in Arc") }
        if row.extensionInfo.install == .managed { parts.append("Installed by your organization in Arc") }
        if state != .installed, let said = outcome(row) { parts.append(said) }
        else {
            switch state {
            case .opened: parts.append("Opened in the Web Store: choose Add to Chrome there")
            case .unavailable(let why): parts.append(why)
            default: break
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Flashes the scroller once when the list first shows more rows than fit, as AppKit does for a new scroll view, so
/// the list says it scrolls even with "Show scroll bars: When scrolling" (macOS 15; the fade says it on macOS 14).
private struct FlashScrollerOnAppear: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.scrollIndicatorsFlash(onAppear: enabled) }
        else { content }
    }
}
