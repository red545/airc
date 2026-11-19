// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircImport
import AircKit
import AppKit
import SwiftUI

/// Settings categories (SET-1, design §7 "Settings page").
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, boosts, links, profiles, siteSearch = "sitesearch", spaces, sync, appearance, ai, agents, shortcuts, importing = "import", passwords, privacy, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .boosts: "Boosts"
        case .general: "General"
        case .links: "Links"
        case .profiles: "Profiles"
        case .siteSearch: "Site Search"
        case .spaces: "Spaces"
        case .sync: "Sync"
        case .appearance: "Appearance"
        case .ai: "AI"
        case .agents: "Agents"
        case .shortcuts: "Shortcuts"
        case .importing: "Import"
        case .passwords: "Passwords"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .boosts: "paintbrush.pointed"
        case .general: "gearshape"
        case .links: "link"
        case .profiles: "person.2"
        case .siteSearch: "magnifyingglass"
        case .spaces: "square.stack"
        case .sync: "icloud"
        case .appearance: "paintpalette"
        case .ai: "sparkles"
        case .agents: "cursorarrow.rays"
        case .shortcuts: "command"
        case .importing: "square.and.arrow.down"
        case .passwords: "key.fill"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }

    /// The tinted square behind the symbol (macOS Settings style).
    var tint: AircColor {
        switch self {
        case .boosts: AircColor(0x8A5CF6)
        case .general: AircColor.Stone.s500
        case .links: AircColor(0x2F80ED)
        case .profiles: AircColor(0x3139FB)
        case .siteSearch: AircColor(0x0FA5A5)
        case .spaces: AircColor(0x2F9E62)
        case .sync: AircColor(0x3A8FE8)
        case .appearance: AircColor(0xE0559F)
        case .ai: AircColor(0x8A5CF6)
        case .agents: AircColor(0xD9773F)
        case .shortcuts: AircColor.Stone.s700
        case .importing: AircColor(0xF08A4B)
        case .passwords: AircColor(0x8E8E93)
        case .privacy: AircColor(0x5B63EE)
        case .about: AircColor.Stone.s500
        }
    }
}

/// What the Settings window shows; republishes store and settings changes.
final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage = .general
    /// whatsnew2: a section title to scroll to (WhatsNewPage's "Show me"), with a count so the same one scrolls again.
    /// settingsux: or a search result's row (its anchors, tried in order; the last one shown wins).
    @Published private(set) var revealRequest: (targets: [String], n: Int)?
    /// The section the page scrolled to last (the checks read it).
    var revealed: String?

    func reveal(_ section: String) {
        revealRequest = ([section], (revealRequest?.n ?? 0) + 1)
    }

    // MARK: settingsux: search

    /// The search field's text; results replace the pane list while it isn't empty.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            results = SettingsSearch.results(for: query)
            selection = nil
        }
    }
    @Published private(set) var results: [SettingsSearch.Entry] = []
    /// The result ↑↓ selected (nil: none yet; Return opens the first).
    @Published var selection: Int?
    /// Anchors highlighted now (a found row or section, for a moment).
    @Published private(set) var highlight: Set<String> = []
    private var highlightToken = 0
    /// ⌘F: SettingsRoot's field takes the keyboard (a count, so the same request focuses again).
    @Published private(set) var focusSearchRequest = 0
    /// The result opened last (the checks read it).
    private(set) var opened: SettingsSearch.Entry?

    func focusSearch() { focusSearchRequest += 1 }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, (selection ?? -1) + delta))
    }

    /// Opens a result: its pane, scrolled to its row or section, which is highlighted for a moment.
    func open(_ entry: SettingsSearch.Entry) {
        opened = entry
        page = entry.page
        guard entry.kind != .page else { return }
        revealRequest = (entry.scrollTargets.reversed(), (revealRequest?.n ?? 0) + 1)
        highlightToken += 1
        let token = highlightToken
        highlight = Set(entry.anchors)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.highlightToken == token else { return }
            self.highlight = []
        }
    }

    /// Return in the field: the selected result, else the first.
    func openSelection() {
        guard !results.isEmpty else { return NSSound.beep() }
        open(results[min(selection ?? 0, results.count - 1)])
    }
    weak var app: AppDelegate?
    let store: SpacesStore
    let settings: AppSettings
    private var token: Int?
    private var settingsSink: Any?

    init(app: AppDelegate) {
        self.app = app
        store = app.store
        settings = app.settings
        token = store.observe { [weak self] change in
            guard change.touches(.profile) || change.touches(.space) else { return }
            self?.objectWillChange.send()
        }
        settingsSink = settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    deinit { if let token { store.removeObserver(token) } }

    var controller: WindowController? { app?.controller }

    var protectedContentAvailable: Bool { app?.engine.supportsProtectedContent == true }
    var protectedContentEnabled: Bool {
        get { app?.engine.protectedContentEnabled ?? false }
        set {
            guard let engine = app?.engine, engine.supportsProtectedContent else { return }
            objectWillChange.send()
            engine.protectedContentEnabled = newValue
        }
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    let window: NSWindow

    init(app: AppDelegate) {
        model = SettingsModel(app: app)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.windowWidth, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: SettingsLayout.windowWidth, height: 560)
        window.tabbingMode = .disallowed
        window.delegate = self
        let root = SettingsRoot(model: model)
        window.contentView = onMain { NSHostingView(rootView: root) }
        window.center()
        // settingsux: ⌘F is Settings search here, not the browser window's Find (whose menu item would take it).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "f" else { return event }
            self.model.focusSearch()
            return nil
        }
    }
    private var keyMonitor: Any?

    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func show(focus: Bool) {
        if focus {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }
}

/// settingsux: the Settings window's fixed geometry. The pane's column is always `columnWidth` wide, and the window is
/// never narrower than the sidebar, the column, its margins and a legacy (always shown) scroll bar, so switching panes
/// never moves the layout. Before, the column took what was left of a 780-pt window (523 pt) while Appearance's App
/// Icon row was 544 pt wide; a vertical ScrollView centres content wider than itself, so that pane moved left.
enum SettingsLayout {
    static let sidebarWidth: CGFloat = 200
    static let columnWidth: CGFloat = 560
    static let margin: CGFloat = 28
    static let scrollerAllowance: CGFloat = 16
    static var windowWidth: CGFloat { sidebarWidth + 0.5 + margin * 2 + columnWidth + scrollerAllowance }
}

private struct SettingsRoot: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme

    private var theme: ResolvedTheme { DesignTheme.default.resolved(systemIsDark: scheme == .dark) }

    var body: some View {
        HStack(spacing: 0) {
            sourceList
            Rectangle().fill(theme.surfaceBorder.color).frame(width: 0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.page.title).aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
                            .padding(.bottom, 4)
                        page
                    }
                    // A fixed width, leading: a row wider than the column can't make the ScrollView centre (move) it.
                    .frame(width: SettingsLayout.columnWidth, alignment: .leading)
                    .testAnchor("settings.column")
                    .padding(SettingsLayout.margin)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // whatsnew2: "Show me" scrolls to its section (SettingsSection's id is its title), once the page is drawn.
                .onChange(of: model.revealRequest?.n) { _, _ in reveal(proxy) }
                .onAppear { reveal(proxy) }   // a window made for the request: no change to see
            }
            .background(theme.surface.color)
            .environment(\.aircRowHighlight, model.highlight)   // settingsux: rows get scroll ids and the found-row highlight
        }
        .aircTheme(theme)
        .frame(minWidth: SettingsLayout.windowWidth, minHeight: 560)
        .ignoresSafeArea()
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let targets = model.revealRequest?.targets, let first = targets.last else { return }
        // A section goes to the top (whatsnew2); a found row a little below it, with its section title in view.
        let anchor: UnitPoint = targets.count == 1 && !first.hasPrefix("row:") ? .top : UnitPoint(x: 0.5, y: 0.3)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                // Tried in order (the section, then the row): an id that isn't shown now does nothing, so the row wins
                // when it's there.
                for id in targets { proxy.scrollTo(id, anchor: anchor) }
            }
            model.revealed = first
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsSearchField(model: model)
                .padding(.bottom, 8)
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                paneList
            } else {
                SettingsSearchResults(model: model)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .frame(width: SettingsLayout.sidebarWidth)
        .background((theme.isDark ? AircColor(0x171412) : AircColor.Stone.s50).color)
    }

    @ViewBuilder private var paneList: some View {
            ForEach(SettingsPage.allCases) { p in
                let on = p == model.page
                HStack(spacing: 8) {
                    Image(systemName: p.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(p.tint.color))
                    Text(p.title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? theme.accent.alpha(0.14).color : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.page = p }
                .testAnchor("settings.pane." + p.rawValue)
            }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .boosts: BoostsSettingsPage(model: model)
        case .general: GeneralPage(model: model)
        case .links: LinksPage(model: model)
        case .profiles: ProfilesPage(model: model)
        case .siteSearch: SiteSearchSettingsPage(model: model)
        case .spaces: SpacesPage(model: model)
        case .sync: SyncSettingsPage(model: model)
        case .appearance: AppearancePage(model: model)
        case .ai: AIPage(model: model)
        case .agents: AgentsPage(model: model)
        case .shortcuts: ShortcutsPage(model: model)
        case .importing: ImportPage(model: model)
        case .passwords: VStack(alignment: .leading, spacing: 0) { PasswordManagerSettingsSection(model: model) }
        case .privacy: PrivacyPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

// MARK: - Building blocks

/// A section: `title3` heading 24 pt above an AircGroup, optional help under it.
struct SettingsSection<Content: View>: View {
    let title: String
    var help: String?
    @ViewBuilder let content: Content
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                .background(SettingsSectionHighlight(anchor: SettingsSearch.sectionAnchor(title)))
            AircGroup { content }
            if let help {
                Text(help).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 24)
        .id(title)   // whatsnew2: SettingsModel.reveal scrolls to it
    }
}

/// A row: title (and subtitle) leading, a control trailing. ≥ 44 pt.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: Trailing
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                if let subtitle {
                    Text(subtitle).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .aircRowAnchor(title)   // settingsux: search scrolls to and highlights it
        .testAnchor("settings.row." + title)
    }
}

/// settingsux: a found section's title is marked for a moment, as a found row is (AircRowAnchor).
private struct SettingsSectionHighlight: View {
    let anchor: String
    @Environment(\.aircRowHighlight) private var highlight
    @Environment(\.aircTheme) private var theme

    var body: some View {
        let on = highlight?.contains(anchor) == true
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(theme.accent.alpha(theme.isDark ? 0.24 : 0.16).color)
            .padding(.horizontal, -6).padding(.vertical, -2)
            .opacity(on ? 1 : 0)
            .animation(.easeOut(duration: on ? 0.15 : 0.6), value: on)
            .allowsHitTesting(false)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var defaultBrowser = DefaultBrowser.shared
    @State private var lastBackup: String?
    #if canImport(Sparkle)
    @State private var updateChannel = AircUpdateDelegate.selectedChannel
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Default browser") {
                SettingsRow(title: defaultBrowser.isDefault ? "Airc is your default browser" : "Open links from other apps in Airc",
                            subtitle: "Links from Mail, Slack and others open in your most recent Space.") {
                    if !defaultBrowser.isDefault {
                        Button("Make Default") { SettingsActions.makeDefaultBrowser { _ in } }
                            .buttonStyle(.airc(.secondary))
                            .disabled(defaultBrowser.isAsking)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(AircColor(0x2F9E62).color)
                    }
                }
            }
            #if canImport(Sparkle)
            if Bundle.main.object(forInfoDictionaryKey: "AircDevChannel") as? Bool != true {
                SettingsSection(title: "Updates", help: "Nightly includes newer, less tested changes. Switching back to Stable waits for a newer stable build; it never downgrades your data.") {
                    SettingsRow(title: "Update channel") {
                        AircPopUp(options: [("Stable", "stable"), ("Nightly", "nightly")], selection: updateChannel) { value in
                            updateChannel = value
                            AircUpdateDelegate.selectedChannel = value
                        }
                    }
                }
            }
            UpdateWhenIdleSection(model: model)   // E13 (Browser/UpdateButton.swift)
            #endif
            StartupWindowsSection(model: model)   // E12 (Settings/AppPersonalization.swift)
            SoundsAndHapticsSection(model: model)   // E15 (Settings/AppPersonalization.swift)
            DeveloperSettingsSection(model: model)   // DEV-1 (Browser/DeveloperMode.swift)
            PictureInPictureSection(model: model)
            SettingsSection(title: "Shared Quotes") {
                // P01c (Browser/SelectionShare.swift): Arc's shareQuoteLinkEnabled, on by default.
                AircToggleRow("Enable Shared Quotes when highlighting text", subtitle: "After ⌘C on text you selected in a page, Airc offers a link straight to that text.",
                              isOn: Binding(get: { model.settings.values.sharedQuotes }, set: { model.settings.values.sharedQuotes = $0 }))
            }
            CalendarSettingsSection(model: model)
            NoteAppSettingsSection(model: model)   // Notes/NoteExport.swift
            SettingsSection(title: "Command Bar", help: "Suggestions come from each profile's own search engine, with no cookies, so profiles never mix.") {
                AircToggleRow("Search suggestions", subtitle: "What you type goes to the search engine as you type.",
                              isOn: Binding(get: { model.settings.values.suggestionsEnabled }, set: { model.settings.values.suggestionsEnabled = $0 }))
            }
            SettingsSection(title: "Memory", help: "Every profile stays loaded; only pages you haven't looked at for a while are put to sleep.") {
                SettingsRow(title: "Unload tabs you haven't looked at for",
                            subtitle: "Frees their memory; they reload when you come back. Never the tab you're on, one playing sound, or one with something typed in.") {
                    AircPopUp(options: [("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60), ("4 hours", 240), ("Never", 0)],
                              selection: model.settings.values.unloadAfterMinutes) { v in
                        model.settings.values.unloadAfterMinutes = v
                        model.app?.controllers.forEach { $0.applyUnloadSetting() }
                    }
                }
                AircToggleRow("Keep chat and mail sites loaded",
                              subtitle: "Pinned tabs and Favorites of Gmail, Google Calendar, Slack, Discord, WhatsApp, Teams, Outlook and similar sites never unload, so their notifications and calls keep coming.",
                              isOn: Binding(get: { model.settings.values.keepChatSitesLoaded }, set: { v in
                                  model.settings.values.keepChatSitesLoaded = v
                                  model.app?.controllers.forEach { $0.applyUnloadSetting() }
                              }))
            }
            SettingsSection(title: "Backups", help: "Airc keeps a JSON copy of your Spaces, tabs and Favorites every day, the last 14 days. An iCloud Drive folder works.") {
                SettingsRow(title: "Back up to", subtitle: backupFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Button("Choose…") { chooseFolder() }.buttonStyle(.airc(.secondary))
                }
                SettingsRow(title: "Back up now", subtitle: lastBackup) {
                    HStack(spacing: 8) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backupFolder]) }.buttonStyle(.airc(.plain))
                        Button("Back Up") { backUpNow() }.buttonStyle(.airc(.secondary))
                    }
                }
            }
        }
    }

    private var backupFolder: URL { model.settings.backupDirectory }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.settings.values.backupFolder = url.path }
    }

    private func backUpNow() {
        do {
            if let url = try model.settings.backUp(model.store, purpose: .manual) {
                lastBackup = "Saved " + url.lastPathComponent
            }
        } catch {
            lastBackup = "Couldn't back up: \(error.localizedDescription)"
        }
    }
}

// MARK: - Links (AT-1, LA-1)

/// Air Traffic Control: where links from other apps go. Rules in order ("URL contains / is … → Space"), then the
/// default: Little Arc or the most recent Space.
private struct LinksPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var defaultBrowser = DefaultBrowser.shared
    @Environment(\.aircTheme) private var theme

    private var rules: [LinkRule] { model.settings.values.linkRules }
    private var spaces: [(String, String)] {
        model.store.orderedSpaces.map { s in
            let emoji: String = if case .emoji(let e)? = s.icon { e + " " } else { "" }
            return (emoji + s.name, s.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Links from other apps", help: "Links from Mail, Slack and others come here when Airc is your default browser.") {
                SettingsRow(title: defaultBrowser.isDefault ? "Airc is your default browser" : "Airc isn't your default browser") {
                    if !defaultBrowser.isDefault {
                        Button("Make Default") { SettingsActions.makeDefaultBrowser { _ in } }.buttonStyle(.airc(.secondary))
                            .disabled(defaultBrowser.isAsking)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(AircColor(0x2F9E62).color)
                    }
                }
                SettingsRow(title: "When no rule matches, open them in",
                            subtitle: model.settings.values.externalLinks == .littleArc
                                ? "A Little Airc window in the profile remembered for the site, or your most recent Space’s profile. ⌘O moves it into the Space."
                                : "A new tab in your most recent Space.") {
                    AircPopUp(options: [("Little Airc", ExternalLinkTarget.littleArc), ("Most recent Space", .recentSpace)],
                              selection: model.settings.values.externalLinks, width: 170) { model.settings.values.externalLinks = $0 }
                }
            }
            LittleArcGlobalSettingsSection(settings: model.settings)
            SettingsSection(title: "Remembered profiles", help: "Little Airc remembers the profile you choose for each site. Air Traffic Control rules always win.") {
                SettingsRow(title: "Little Airc", subtitle: "Sites remembered: \(model.settings.values.littleArcProfiles.domains.count)") {
                    Button("Forget remembered profiles") { model.settings.values.littleArcProfiles = LittleArcProfiles() }
                        .buttonStyle(.airc(.secondary))
                        .disabled(model.settings.values.littleArcProfiles.domains.isEmpty)
                }
            }
            SettingsSection(title: "Peek", help: "A card over the page. ⌘O makes it a tab; Esc or a click outside closes it.") {
                AircToggleRow("Open links in Peek", subtitle: "⇧-clicked links, and other sites a pinned tab or Favorite opens in a new tab.",
                              isOn: Binding(get: { model.settings.values.peekEnabled }, set: { model.settings.values.peekEnabled = $0 }))
            }
            SettingsSection(title: "Air Traffic Control",
                            help: "For links from other apps and links that would open in Peek, the first rule wins. A link opens in the rule's Space, already signed in, because the Space carries its profile.") {
                ForEach(Array(rules.enumerated()), id: \.element.id) { i, rule in ruleRow(i, rule) }
                SettingsRow(title: rules.isEmpty ? "No rules yet" : "Another rule", subtitle: rules.isEmpty ? "Like “URL contains figma.com → Design”." : nil) {
                    Button("Add Rule") {
                        model.settings.values.linkRules.append(LinkRule(pattern: "", spaceID: model.store.selectedSpace.id))
                        Telemetry.shared.record(.featureUsed(.airTrafficRuleAdd))
                    }
                    .buttonStyle(.airc(.secondary))
                    .disabled(model.store.orderedSpaces.isEmpty)
                }
            }
        }
    }

    private func ruleRow(_ i: Int, _ rule: LinkRule) -> some View {
        HStack(spacing: 8) {
            AircPopUp(options: [("URL contains", LinkRule.Match.contains), ("URL is", .equals)], selection: rule.match, width: 152) { m in
                update(rule.id) { $0.match = m }
            }
            AircTextField(text: Binding(get: { rule.pattern }, set: { v in update(rule.id) { $0.pattern = v } }),
                          placeholder: rule.match == .contains ? "figma.com" : "https://example.com/page")
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.surfaceTextTertiary.color)
            AircPopUp(options: spaces, selection: rule.spaceID, width: 140) { sid in update(rule.id) { $0.spaceID = sid } }
            Button { model.settings.values.linkRules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.airc(.plain)).accessibilityLabel("Remove rule")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    private func update(_ id: String, _ change: (inout LinkRule) -> Void) {
        guard let i = model.settings.values.linkRules.firstIndex(where: { $0.id == id }) else { return }
        change(&model.settings.values.linkRules[i])
    }
}

// MARK: - Picture in Picture (SB-55)

/// The off switch, per-site exceptions and the position reset. They apply to every profile.
struct PictureInPictureSection: View {
    @ObservedObject var model: SettingsModel
    @State private var newSite = ""
    @State private var problem: String?
    @State private var resetDone = false
    @Environment(\.aircTheme) private var theme

    private var supported: Bool { model.controller?.supportsPictureInPictureSettings ?? false }
    private var sites: [(String, Bool)] { model.settings.values.pipSites.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }

    var body: some View {
        SettingsSection(title: "Picture in Picture",
                        help: supported ? "When you leave a tab that's playing a video or is in a call, it keeps going in a floating window "
                            + "at the bottom right. Drag it anywhere; it remembers. Calls like Google Meet keep their own mute, camera and leave buttons."
                            : "Comes with the Chromium engine.") {
            AircToggleRow("Pop out videos and calls when you leave their tab",
                          subtitle: "Never for muted autoplay or a tab that only plays sound.",
                          isOn: Binding(get: { model.settings.values.pipAutomatic }, set: {
                              model.settings.values.pipAutomatic = $0
                              model.controller?.applyPictureInPictureSettings()
                          }))
                .disabled(!supported)
            ForEach(sites, id: \.0) { origin, on in
                SettingsRow(title: origin.replacingOccurrences(of: "https://", with: ""),
                            subtitle: on ? "Pops out (while the switch above is on)" : "Never pops out") {
                    HStack(spacing: 8) {
                        AircPopUp(options: [("Always", true), ("Never", false)], selection: on, width: 100) { v in
                            model.settings.values.pipSites[origin] = v
                            model.controller?.applyPictureInPictureSettings()
                        }
                        Button { remove(origin) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.airc(.plain)).accessibilityLabel("Remove \(origin)")
                    }
                }
            }
            SettingsRow(title: "Add a site", subtitle: problem ?? "Like meet.google.com") {
                HStack(spacing: 8) {
                    AircTextField(text: $newSite, placeholder: "meet.google.com", isError: problem != nil)
                        .frame(width: 180)
                        .onSubmit { add(true) }
                    Button("Always") { add(true) }.buttonStyle(.airc(.secondary)).fixedSize()
                    Button("Never") { add(false) }.buttonStyle(.airc(.secondary)).fixedSize()
                }
                .fixedSize()
                .disabled(!supported)
            }
            SettingsRow(title: "Position", subtitle: resetDone ? "The next one opens at the bottom right." : "Back to the bottom right of the screen.") {
                Button("Reset Position") {
                    model.controller?.resetPictureInPicturePosition()
                    resetDone = true
                }
                .buttonStyle(.airc(.secondary)).disabled(!supported)
            }
        }
    }

    private func add(_ on: Bool) {
        guard let origin = WindowController.pictureInPictureOrigin(newSite) else {
            problem = "That isn't a web address."
            return
        }
        problem = nil
        newSite = ""
        model.settings.values.pipSites[origin] = on
        model.controller?.applyPictureInPictureSettings()
    }

    private func remove(_ origin: String) {
        model.settings.values.pipSites[origin] = nil
        model.controller?.applyPictureInPictureSettings(cleared: [origin])
    }
}

// MARK: - Profiles (SP-14)

private struct ProfilesPage: View {
    @ObservedObject var model: SettingsModel
    @State private var deleting: Profile?
    @State private var confirmText = ""
    @State private var clearing: Profile?
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Each Profile keeps its own logins, history, saved passwords and extensions, so the Spaces that use it stay apart from the rest.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.store.orderedProfiles) { p in
                ProfileSection(model: model, profile: p, onDelete: { deleting = p; confirmText = "" }, onClear: { clearing = p })
            }
            HStack {
                Spacer()
                Button("New Profile…") { model.controller?.openCreateProfile(forSpace: nil); model.app?.controller?.window.makeKeyAndOrderFront(nil) }
                    .buttonStyle(.airc(.secondary))
                    .help("Opens Create Profile over the browser window")
            }
            .padding(.top, 16)
        }
        .sheet(item: $deleting) { p in deleteSheet(p) }
        .alert("Clear “\(clearing?.name ?? "")”’s browsing data?", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
            Button("Clear Data", role: .destructive) { if let p = clearing { SettingsActions.clearData(of: p.id, model: model) }; clearing = nil }
            Button("Cancel", role: .cancel) { clearing = nil }
        } message: {
            Text("Signs this profile out of every site and deletes its cookies, cache and history. Its Spaces, pinned tabs and Favorites stay.")
        }
    }

    /// Arc's rule: type the profile's name to delete it, and only once no Space uses it.
    private func deleteSheet(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete “\(p.name)”?").aircFont(AircFont.title2).foregroundStyle(theme.surfaceText.color)
            Text("Deleting \(p.name) will permanently remove any cookies, history, preferences, and logins that belong to this Profile. Type the Profile’s name to confirm:")
                .aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            AircTextField("Type “\(p.name)” to confirm", text: $confirmText, placeholder: p.name)
            HStack {
                Spacer()
                Button("Cancel") { deleting = nil }.buttonStyle(.airc(.plain)).keyboardShortcut(.cancelAction)
                Button("Delete Profile") {
                    let app = model.app
                    // The AI features first, while the profile's pages and sessions can still be matched to it.
                    AIFeatures.shared.forget(profileID: p.id)
                    app?.profiles.deleteProfile(p.id) { ok in
                        if ok {
                            app?.history.clear(profileID: p.id)
                            SiteIcons.shared.forgetAll()   // the Command Bar's icons by site
                            ServicePreviewCenter.shared.forget(profileID: p.id)   // its tab pictures and site previews (P11a)
                            app?.settings.values.siteSearch.forget(profileID: p.id)
                        } else {
                            app?.controller?.showToast("Airc couldn't delete \(p.name)'s data, so the profile is kept")
                        }
                    }
                    deleting = nil
                }
                .buttonStyle(.airc(.destructive))
                .disabled(confirmText != p.name)
            }
        }
        .padding(24)
        .frame(width: 400)
        .aircTheme(theme)
    }
}

/// Settings › Profiles' search row (C08, C08b).
enum ProfileSearchRow {
    /// Its subtitle when a site search is the default (P07d, or an imported custom default).
    static func subtitle(_ siteSearch: SiteSearchSettings, profileID: String) -> String? {
        siteSearch.defaultSite(for: profileID).map { "Searching with \($0.name), from Site Search." }
    }
}

private struct ProfileSection: View {
    @ObservedObject var model: SettingsModel
    let profile: Profile
    let onDelete: () -> Void
    let onClear: () -> Void
    @State private var name = ""
    @State private var problem: String?
    @Environment(\.aircTheme) private var theme

    private var spaces: [Space] { model.store.spaces(usingProfile: profile.id) }


    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AircProfileAvatar(emoji: profile.emoji, name: profile.name, color: profile.color.aircColor, size: 28)
                Text(profile.name).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                if profile.isDefault {
                    Text("Default").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(theme.surfaceText.alpha(0.06).color))
                }
                Spacer()
                Text(spaces.count == 1 ? "1 Space" : "\(spaces.count) Spaces").aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextTertiary.color)
            }
            AircGroup {
                SettingsRow(title: "Name") {
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .aircFont(AircFont.body)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 180)
                        .onSubmit(rename)
                        .onAppear { name = profile.name }
                }
                SettingsRow(title: "Emoji and colour") {
                    HStack(spacing: 6) {
                        TextField("", text: Binding(get: { profile.emoji }, set: { v in
                            try? model.store.updateProfile(profile.id) { $0.emoji = String(v.prefix(2)) }
                        }))
                        .textFieldStyle(.plain).frame(width: 28).multilineTextAlignment(.center)
                        AircProfileColorPicker(selection: Binding(
                            get: { AircProfileColor.nearestChoice(to: profile.color.aircColor) },
                            set: { i in try? model.store.updateProfile(profile.id) { $0.color = RGBA(AircProfileColor.choices[i]) } }
                        ), size: 16)
                    }
                }
                SettingsRow(title: "Archive Today tabs after", subtitle: "Tabs playing audio and the one you're looking at stay.") {
                    AircPopUp(options: ArchiveInterval.allCases.map { ($0.label, $0) }, selection: profile.archiveAfter) { v in
                        try? model.store.updateProfile(profile.id) { $0.archiveAfter = v }
                    }
                }
                SettingsRow(title: "Default search engine",
                            subtitle: ProfileSearchRow.subtitle(model.settings.values.siteSearch, profileID: profile.id)) {
                    AircPopUp(options: SearchEngine.allCases.map { ($0.name, $0) }, selection: profile.searchEngine) { v in
                        try? model.store.updateProfile(profile.id) { $0.searchEngine = v }
                    }
                    .testAnchor("profile.searchEngine")
                    .testAnchor("profile.searchEngine." + profile.id)
                }
                // C08: Arc's per-profile "Include search engine suggestions".
                AircToggleRow("Include search engine suggestions",
                              subtitle: model.settings.values.suggestionsEnabled
                                ? "What you type in the Command Bar goes to this profile's search engine, without cookies."
                                : "Off for every profile in Privacy.",
                              isOn: Binding(get: { profile.includesSearchSuggestions },
                                            set: { v in try? model.store.updateProfile(profile.id) { $0.searchSuggestions = v } }))
                SettingsRow(title: "Google account", subtitle: profile.googleAccount ?? "Not signed in") {
                    Button(profile.googleAccount == nil ? "Sign In…" : "Switch…") { SettingsActions.signIn(profile: profile, model: model) }
                        .buttonStyle(.airc(.secondary))
                }
                if let center = BlockingCenter.shared { BlockingProfileRows(center: center, profile: profile.id) }
                SettingsRow(title: "Browsing data", subtitle: "Cookies, cache and history of this profile.") {
                    Button("Clear…", action: onClear).buttonStyle(.airc(.secondary))
                }
                if !profile.isDefault {
                    SettingsRow(title: "Delete profile", subtitle: spaces.isEmpty ? nil : "Move its Spaces to another profile first.") {
                        Button("Delete Profile…", action: onDelete).buttonStyle(.airc(.destructive)).disabled(!spaces.isEmpty)
                    }
                }
            }
            if let problem { Text(problem).aircFont(AircFont.callout).foregroundStyle(AircColor.destructive.color) }
        }
        .padding(.top, 24)
    }

    private func rename() {
        switch model.store.validateProfileName(name, excluding: profile.id) {
        case .taken?: problem = "There’s already a Profile with this name."
        case .empty?, .tooLong?: problem = "Invalid Profile name."
        case nil:
            problem = nil
            try? model.store.updateProfile(profile.id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

// MARK: - Spaces

private struct SpacesPage: View {
    @ObservedObject var model: SettingsModel
    @State private var deleting: Space?
    @Environment(\.aircTheme) private var theme

    var body: some View {
        let spaces = model.store.orderedSpaces
        VStack(alignment: .leading, spacing: 0) {
            Text("Drag to reorder. The order is the Space bar's, left to right, and ⌃1–9.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
            List {
                ForEach(spaces) { s in SpaceRow(model: model, space: s, onDelete: { deleting = s }) }
                    .onMove { from, to in
                        guard let i = from.first else { return }
                        let id = spaces[i].id
                        try? model.store.moveSpace(id, to: to > i ? to - 1 : to)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(theme.surfaceBorder.color)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: max(120, CGFloat(spaces.count) * 50 + 8))
            .background(RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous)
                .fill((theme.isDark ? AircColor.white(0.035).over(theme.surface) : AircColor.white()).color))
            .overlay(RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous).inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
            .padding(.top, 16)
            HStack {
                Spacer()
                Button("New Space…") { model.controller?.openNewSpacePanel(); model.controller?.window.makeKeyAndOrderFront(nil) }
                    .buttonStyle(.airc(.secondary))
            }
            .padding(.top, 16)
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Space", role: .destructive) {
                if let s = deleting {
                    if let c = model.controller { c.deleteSpace(s.id) } else { try? model.store.deleteSpace(s.id) }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its pinned tabs are deleted and its Today tabs go to the Archive. ⌘Z in the browser undoes it.")
        }
    }
}

private struct SpaceRow: View {
    @ObservedObject var model: SettingsModel
    let space: Space
    let onDelete: () -> Void
    @State private var name = ""
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.surfaceTextTertiary.color)
            AircThemeDisc(theme: space.theme.design.resolved(systemIsDark: theme.isDark), size: 22)
            if space.icon == nil {
                // No icon: the 6 pt ink dot at 0.6, not a black disc (visual review #20).
                Circle().fill(theme.surfaceText.alpha(0.6).color).frame(width: 6, height: 6).frame(width: 22)
            } else {
                Text(space.iconLabel).font(.system(size: 15)).frame(width: 22)
            }
            TextField("", text: $name)
                .textFieldStyle(.plain)
                .aircFont(AircFont.body)
                .onSubmit { try? model.store.updateSpace(space.id) { $0.name = name.isEmpty ? $0.name : name } }
                .onAppear { name = space.name }
            Spacer()
            AircPopUp(options: model.store.orderedProfiles.map { p in (p.emoji.isEmpty ? p.name : "\(p.emoji) \(p.name)", p.id) },
                      selection: space.profileID, width: 140) { pid in
                if let c = model.controller { c.changeProfile(ofSpace: space.id, to: pid) } else { _ = try? model.store.setProfile(ofSpace: space.id, to: pid) }
            }
            Menu {
                ForEach(DesignTheme.presets) { p in
                    Button(p.name) { try? model.store.updateSpace(space.id) { $0.theme = p.theme.model } }
                }
            } label: { Image(systemName: "paintpalette") }
            .menuStyle(.borderlessButton).frame(width: 34)
            .help("Theme")
            Button(action: onDelete) { Image(systemName: "trash").foregroundStyle(theme.surfaceTextSecondary.color) }
                .buttonStyle(.airc(.plain, size: .small))
                .disabled(model.store.state.spaces.count < 2)
                .help("Delete Space")
        }
        .frame(height: 42)
    }
}

// MARK: - Appearance

private struct AppearancePage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.aircTheme) private var theme

    /// Spaces whose theme has its own Light or Dark (which wins over the app's), as of when the page opened.
    @State private var ownAppearanceIDs: [String]?
    private var ownAppearanceSpaces: [Space] {
        let ids = ownAppearanceIDs ?? model.store.orderedSpaces.filter { $0.theme.appearance != .auto && !$0.isBlankWindow }.map(\.id)
        return ids.compactMap { model.store.space($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // darkfix: one appearance for all of Airc; Spaces follow it unless they have their own.
            SettingsSection(title: "Appearance", help: "Auto follows macOS. Light and Dark set all of Airc: windows, the sidebar, Settings and web pages. Every Space follows this, unless you gave it its own Light or Dark in Edit Theme Color….") {
                SettingsRow(title: "Airc") {
                    AircSegmented(selection: Binding(get: { model.settings.values.appearance }, set: { model.settings.values.appearance = $0 }), segments: [
                        .init(value: .auto, title: "Auto", symbol: "sparkles"),
                        .init(value: .light, title: "Light", symbol: "sun.max"),
                        .init(value: .dark, title: "Dark", symbol: "moon"),
                    ])
                    .frame(width: 260)
                    .testAnchor("settings.appearance.app")
                    .onAppear {
                        ownAppearanceIDs = model.store.orderedSpaces.filter { $0.theme.appearance != .auto && !$0.isBlankWindow }.map(\.id)
                    }
                }
                // The rows are the Spaces that had their own appearance when the page opened. A row stays after Follow
                // Airc (it says so) so the page's layout doesn't change under the click: a row removed by its own button
                // left a container over the control above it, which then took no clicks.
                ForEach(ownAppearanceSpaces, id: \.id) { space in
                    let follows = space.theme.appearance == .auto
                    SettingsRow(title: space.name) {
                        HStack(spacing: 10) {
                            Text(follows ? "Follows Airc" : space.theme.appearance == .dark ? "Always Dark (its own theme)" : "Always Light (its own theme)")
                                .aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
                            Button("Follow Airc") {
                                model.objectWillChange.send()
                                try? model.store.updateSpace(space.id) { $0.theme.appearance = .auto }
                            }
                            .buttonStyle(.airc(.secondary, size: .small))
                            .disabled(follows)
                            .testAnchor("settings.appearance.follow." + space.id)
                        }
                    }
                }
            }
            SettingsSection(title: "Window", help: "The desktop shows through each Space's colour faintly, as in Arc. Text always keeps its contrast; inactive windows and Reduce Transparency go opaque.") {
                SettingsRow(title: "Translucency") {
                    AircSegmented(selection: Binding(get: { model.settings.translucency }, set: { t in
                        model.settings.translucency = t
                        model.app?.controllers.forEach { $0.applyTranslucency(t) }   // every window (WIN-7)
                    }), segments: AircTranslucency.allCases.map { .init(value: $0, title: $0.title) })
                    .frame(width: 240)
                }
            }
            SettingsSection(title: "New Spaces", help: "The colour a new Space starts with. New Spaces follow Airc's appearance above.") {
                SettingsRow(title: "Theme") {
                    HStack(spacing: 4) {
                        ForEach(DesignTheme.presets.prefix(8)) { p in
                            let on = model.settings.values.defaultThemePreset == p.id || (model.settings.values.defaultThemePreset == nil && p.id == "paper")
                            AircThemeDisc(theme: p.theme.resolved(systemIsDark: theme.isDark), selected: on, size: 22)
                                .help(p.name)
                                .onTapGesture { model.settings.values.defaultThemePreset = p.id == "paper" ? nil : p.id }
                        }
                    }
                }
            }
            SettingsSection(title: "Sidebar") {
                // WIN-5: every window moves its sidebar at once (Browser/SidebarSide.swift).
                SettingsRow(title: "Sidebar position") {
                    AircSegmented(selection: Binding(get: { model.store.windowState.sidebarOnRight }, set: { onRight in
                        model.objectWillChange.send()
                        model.app?.setSidebarOnRight(onRight)
                    }), segments: [.init(value: false, title: "Left"), .init(value: true, title: "Right")])
                    .frame(width: 160)
                }
                AircToggleRow("Show tab previews", subtitle: "Rest the pointer on a tab to see the page, with pin, Favorites, split and Peek.",
                              isOn: Binding(get: { model.settings.values.tabPreviews }, set: { model.settings.values.tabPreviews = $0 }))
                // feedback2: the footer's speech bubble (Sidebar/SidebarChrome.swift); its right-click › Hide turns this off.
                AircToggleRow("Show Feedback button", subtitle: "A speech bubble beside the + button sends feedback to the Airc team. Help › Send Feedback… and ⌘T always have it.",
                              isOn: Binding(get: { model.settings.values.sidebarFeedbackButton }, set: { model.settings.values.sidebarFeedbackButton = $0 }))
            }
            SitePreviewsSettingsSection(model: model)   // S04 (Previews/SitePreviewsSettings.swift)
            AppIconSettingsSection(model: model)   // E15 (Settings/AppPersonalization.swift)
            SettingsSection(title: "Window") {
                // W07 (Browser/PageDrag.swift): Arc's setting, on by default.
                AircToggleRow("Allow window dragging from the top of webpages", subtitle: "Drag the window from the top of a page, as from a title bar. Hold ⌘ to use the page there.",
                              isOn: Binding(get: { model.settings.values.dragsWindowFromPageTop }, set: { model.settings.values.dragsWindowFromPageTop = $0 }))
            }
        }
    }
}

// MARK: - Import (ON-3, IM-*)

private struct ImportPage: View {
    @ObservedObject var model: SettingsModel
    @State private var status: String?
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Arc", help: "Importing again updates what came over before instead of duplicating it.") {
                SettingsRow(title: "Import from Arc", subtitle: "Spaces, pinned tabs, folders, Favorites, history and an extension reinstall checklist.") {
                    Button("Import…") { model.app?.startOnboarding(mode: .rerun, atImport: true) }.buttonStyle(.airc(.secondary))
                }
                SettingsRow(title: "Back up my Arc data", subtitle: "A zip of Arc's sidebar and profile list in Documents. Arc stops working on 22 December 2026.") {
                    Button("Back Up") { backUpArc() }.buttonStyle(.airc(.secondary)).disabled(LaunchOptions.current.isAutomated)
                }
                SettingsRow(title: "Logins from Arc", subtitle: loginsSummary) { EmptyView() }
            }
            SettingsSection(title: "Other browsers", help: "Chrome, Brave, Edge, Vivaldi, Opera, Firefox, Zen and others: bookmarks and history. Passwords come from a file you export.") {
                SettingsRow(title: "Import from another browser", subtitle: "Each profile becomes an Airc profile with its own Space; its bookmarks bar becomes pinned tabs.") {
                    Button("Import…") { model.app?.startOnboarding(mode: .rerun, atImport: true) }.buttonStyle(.airc(.secondary))
                }
                SettingsRow(title: "Passwords from a CSV file", subtitle: "The file your browser's “Export passwords” saves. Into the profile you pick.") {
                    Button("Import…") {
                        model.app?.startOnboarding(mode: .rerun, atImport: true)
                        model.app?.onboarding?.select(.passwords, picked: true)
                    }.buttonStyle(.airc(.secondary))
                }
            }
            ArcExtensionChecklistView(app: model.app).padding(.top, 20)
            if let o = CredentialImport.lastOutcome, !o.rows.isEmpty {
                // Engine pass 8: what happened to each login and each site's cookies, problems first.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Login import results").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                    ImportResultsView(outcome: o, profileNames: Dictionary(uniqueKeysWithValues: model.store.orderedProfiles.map { ($0.id, $0.name) }),
                                      maxHeight: 280)
                }
                .padding(.top, 24)
            }
            SettingsSection(title: "Onboarding") {
                SettingsRow(title: "Run onboarding again", subtitle: "Import, accounts and colours, the way the first launch did.") {
                    Button("Start") { model.app?.startOnboarding(mode: .rerun) }.buttonStyle(.airc(.secondary))
                }
            }
            BackupRestoreSection(model: model)
            SettingsSection(title: "Airc data") {
                SettingsRow(title: "Export", subtitle: "Profiles, Spaces, pinned tabs, Favorites and Today as JSON.") {
                    Button("Export…") { export() }.buttonStyle(.airc(.secondary))
                }
            }
            if let status { Text(status).aircFont(AircFont.callout).padding(.top, 10) }
        }
    }

    private var loginsSummary: String {
        guard model.app?.credentialSink.acceptsCredentials == true else { return "Logins come over with the Chromium engine." }
        guard let o = CredentialImport.lastOutcome else { return "Not imported in this session. They come over in the import's Logins step." }
        return o.summary
    }

    private func backUpArc() {
        guard let dir = try? AircImportLocator.arcDirectory() else { status = "Arc's folder wasn't found."; return }
        ArcBackup.run(arcDirectory: dir) { url in
            status = url.map { "Saved \($0.lastPathComponent) in Documents." } ?? "The backup failed."
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Airc Export.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.store.exportJSON().write(to: url, options: .atomic)
            status = "Exported to \(url.lastPathComponent)."
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Your password manager (onboarding step 2b, again)

/// Settings › Passwords: the onboarding step on its own, and each profile's "Offer to save and fill passwords" (the
/// step can turn it off): Chromium's saving pref, and whether Airc lists saved logins under a field (an extension's
/// list takes over; PagePrompts.swift drops Airc's).
private struct PasswordManagerSettingsSection: View {
    @ObservedObject var model: SettingsModel
    @State private var offered: [String: Bool] = [:]

    var body: some View {
        SettingsSection(title: "Your password manager",
                        help: model.app?.engine.supportsExtensions == true
                            ? "1Password, Bitwarden, Apple Passwords and others add their extension; Airc's own needs nothing."
                            : "Password manager extensions need the Chromium engine.") {
            SettingsRow(title: "Choose a password manager", subtitle: "The onboarding step: pick one, and add it to the profiles you choose.") {
                Button("Choose…") { model.app?.startOnboarding(mode: .rerun, atPasswordManager: true) }
                    .buttonStyle(.airc(.secondary))
                    .testAnchor("settings.pm.choose")
            }
            ForEach(model.store.orderedProfiles.filter { offered[$0.id] != nil }, id: \.id) { p in
                SettingsRow(title: "Offer to save and fill passwords in \(p.name)",
                            subtitle: "Airc asks to save a login when you sign in, and lists saved logins under the field. Turn it off to let your password manager's extension do both.") {
                    AircSwitch(isOn: Binding(get: { (offered[p.id] ?? true) && !(model.app?.settings.values.passwordFillOff.contains(p.id) ?? false) },
                                             set: { on in set(on, profileID: p.id) }))
                        .accessibilityLabel("Offer to save and fill passwords in \(p.name)")
                        .testAnchor("settings.pm.offer." + p.id)
                }
            }
        }
        .onAppear(perform: load)
        // The step (opened from here) may have turned some off.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in load() }
    }

    private func load() {
        guard let app = model.app else { return }
        for p in model.store.orderedProfiles {
            app.profiles.whenLoaded(p.id) { ep in
                if let v = app.engine.passwordsOffered(for: ep) { offered[p.id] = v }
            }
        }
    }

    private func set(_ on: Bool, profileID: String) {
        guard let app = model.app, let ep = app.profiles.engineProfile(for: profileID) else { return }
        app.setAircPasswords(on, profileID: profileID)
        offered[profileID] = app.engine.passwordsOffered(for: ep)
    }
}

// MARK: - Privacy (SET-4)

private struct PrivacyPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageDataSection(model: model)
            if model.protectedContentAvailable {
                SettingsSection(title: "Protected content", help: "Turning this off applies to newly loaded pages. Reload existing tabs.") {
                    SettingsRow(title: "Play protected content", subtitle: "Downloads and updates Google Widevine for protected music and video.") {
                        AircSwitch(isOn: Binding(get: { model.protectedContentEnabled }, set: { model.protectedContentEnabled = $0 }))
                            .accessibilityLabel("Play protected content")
                    }
                    // docs/user/protected-media.md: the services whose licence servers refuse Chromium's Widevine.
                    SettingsRow(title: "Play DRM sites with Safari's engine",
                                subtitle: "Spotify, Netflix, Disney+ and other services open in a WebKit page, with Apple's FairPlay. Applies to pages opened from now on.") {
                        AircSwitch(isOn: Binding(get: { model.settings.values.webKitProtectedMedia },
                                                 set: { model.settings.values.webKitProtectedMedia = $0 }))
                            .accessibilityLabel("Play DRM sites with Safari's engine")
                    }
                }
            }
            SettingsSection(title: "What else leaves this Mac", help: "No account, no sign-up. Your Spaces, tabs and history stay in Airc's data folder.") {
                SettingsRow(title: "Crash reports", subtitle: "Opt-in, never with URLs or titles. Arrives with v1.") { Text("Off").aircFont(AircFont.mono) }
                SettingsRow(title: "Search suggestions", subtitle: "Typed text goes to the profile's search engine, without cookies.") {
                    AircSwitch(isOn: Binding(get: { model.settings.values.suggestionsEnabled }, set: { model.settings.values.suggestionsEnabled = $0 }))
                }
            }
        }
    }
}

// MARK: - About

private struct AboutPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: AppIconImage.image).resizable().interpolation(.high).frame(width: 112, height: 112)
            Text("Airc").aircFont(AircFont.display).foregroundStyle(theme.surfaceText.color)
            Text("The calm, Arc-style browser for your Mac.").aircFont(AircFont.lead).foregroundStyle(theme.surfaceTextSecondary.color)
            Text(SettingsActions.versionLine(engine: model.app?.engine.name ?? "")).aircFont(AircFont.mono)
                .foregroundStyle(theme.surfaceTextTertiary.color).padding(.top, 6)
            Text("Open source under Apache-2.0. Built and maintained by AI.").aircFont(AircFont.callout)
                .foregroundStyle(theme.surfaceTextTertiary.color)
            HStack(spacing: 8) {
                Button("aircbrowser.com") { NSWorkspace.shared.open(URL(string: "https://aircbrowser.com")!) }.buttonStyle(.airc(.secondary))
                Button("Acknowledgements") { NSApp.orderFrontStandardAboutPanel(nil) }.buttonStyle(.airc(.plain))
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Actions

enum SettingsActions {
    /// Airc opens http and https links (DefaultBrowserPrompt.swift; the rows observe `DefaultBrowser.shared`).
    static var isDefaultBrowser: Bool { DefaultBrowser.shared.isDefault }

    /// One macOS confirmation dialog, as Chromium asks (onboarding step 5 and the reminder card use the same). Refused
    /// in automated runs.
    static func makeDefaultBrowser(_ done: @escaping (Bool) -> Void) {
        DefaultBrowser.shared.makeDefault(done)
    }

    static func clearData(of profileID: String, model: SettingsModel) {
        // The AI features first (Ask on Page's sessions, previews, downloads), before the engine's data goes.
        MainActor.assumeIsolated { AIFeatures.shared.forget(profileID: profileID) }
        model.app?.profiles.engineProfile(for: profileID)?.clearBrowsingData {}
        model.app?.history.clear(profileID: profileID)
        SuggestionService.shared.clear(profileID: profileID)
        ServicePreviewCenter.shared.forget(profileID: profileID)   // its tab pictures and site previews (P11a)
        SiteIcons.shared.forgetAll()   // the Command Bar's icons by site (not per profile: all of them go)
    }

    static func signIn(profile: Profile, model: SettingsModel) {
        guard let c = model.controller, let s = model.store.spaces(usingProfile: profile.id).first else { return }
        c.switchToSpace(s.id, animated: false)
        c.signInToGoogle(spaceID: s.id)
        c.window.makeKeyAndOrderFront(nil)
    }

    static func versionLine(engine: String) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = info["CFBundleVersion"] as? String ?? "dev"
        let rev = info["AircRevision"] as? String
        return "Version \(v) (\(b))" + (rev.map { " · \($0)" } ?? "") + (engine.isEmpty ? "" : " · \(engine)")
    }
}

/// Locates Arc's folder for Settings → Import without reading anything in it.
enum AircImportLocator {
    static func arcDirectory() throws -> URL {
        try ArcImporter.locateData()
    }
}

/// A pop-up in Airc's secondary-button chrome instead of the stock bezel (design.md §7 "Buttons", visual review #20):
/// the current value and ⌃⌄; a click opens a native menu of the options with the current one ticked.
struct AircPopUp<Value: Hashable>: View {
    let options: [(String, Value)]
    let selection: Value
    var width: CGFloat = 130
    let onSelect: (Value) -> Void

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Text(options.first { $0.1 == selection }?.0 ?? "").lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.6)
            }
            .frame(width: width - 28)
        }
        .buttonStyle(.airc(.secondary))
    }

    private func showMenu() {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        let menu = NSMenu()
        var current: NSMenuItem?
        for (title, value) in options {
            let item = menu.add(title) { onSelect(value) }
            if value == selection { item.state = .on; current = item }
        }
        menu.popUp(positioning: current, at: view.convert(event.locationInWindow, from: nil), in: view)
    }
}
