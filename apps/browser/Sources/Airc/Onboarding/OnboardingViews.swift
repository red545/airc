// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircImport
import AircKit
import AppKit
import SwiftUI

/// The onboarding window's content: one step at a time, cross-fading in place (`AircCurve.entrance`), on the window's
/// theme. The window (AircFloatingWindow) draws the theme; the welcome step adds the bloom.
struct OnboardingRoot: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack {
            if model.step == .welcome { WelcomeBloom().transition(.opacity) }
            Group {
                switch model.step {
                case .welcome: WelcomeStep(model: model)
                case .arc: ArcStep(model: model)
                case .accounts: AccountsStep(model: model)
                case .logins: LoginsStep(model: model)
                case .theme: ThemeStep(model: model)
                case .defaultBrowser: DefaultBrowserStep(model: model)
                case .done: DoneStep(model: model)
                }
            }
            .id(model.step)
            .transition(.airc(.asymmetric(insertion: .opacity.combined(with: .offset(x: CGFloat(model.direction) * 14)),
                                          removal: .opacity)))
        }
        .aircAnimation(AircCurve.entrance, value: model.step)
        .frame(width: AircMetrics.Onboarding.windowSize.width, height: AircMetrics.Onboarding.windowSize.height)
        .overlay(alignment: .topTrailing) {
            // A re-run can be left from every step (ON-3); centred on the step dots' row, 22 pt from the corner.
            if model.closable {
                OnboardingCloseButton(model: model, onCard: ![.welcome, .done].contains(model.step))
                    .padding(.top, 22).padding(.trailing, 22)
            }
        }
        .overlay(alignment: .bottom) {
            if model.showsQuitHint {
                Text("Hold ⌘Q to Quit")
                    .aircFont(AircFont.callout.weight(.medium))
                    .foregroundStyle(AircColor.white(0.95).color)
                    .padding(.horizontal, 14)
                    .frame(height: AircMetrics.Toast.height)
                    .background(Capsule().fill(AircColor.black(0.72).color))
                    .padding(.bottom, 74)
                    .transition(.opacity)
            }
        }
        .aircAnimation(AircCurve.previewIn, value: model.showsQuitHint)
        .testAnchor("onboarding.page")
        .testAnchorRoot()
    }
}

/// The ✕ that leaves a re-run (ON-3). Disabled, with the reason as its tooltip, while the logins are being written.
struct OnboardingCloseButton: View {
    @ObservedObject var model: OnboardingModel
    /// On the step card (surface ink) or straight on the theme (the welcome and done steps).
    let onCard: Bool
    @Environment(\.aircTheme) private var theme
    @State private var hovering = false

    var body: some View {
        let blocked = model.closeBlockedReason != nil
        let ink = onCard ? theme.surfaceText : theme.text
        let lit = hovering && !blocked
        Button { model.onClose?() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink.alpha(lit ? 0.78 : 0.48).color)
                .frame(width: 26, height: 26)
                .background(Circle().fill(ink.alpha(lit ? 0.08 : 0).color))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .opacity(blocked ? 0.45 : 1)
        .onHover { hovering = $0 }
        .help(model.closeBlockedReason ?? "Close (⌘W)")
        .accessibilityLabel("Close")
        .testAnchor("onboarding.close")
    }
}

/// The icon's pastels (mint, sky, lilac, pink) blooming over white 0.84, with fine grain (design §7).
struct WelcomeBloom: View {
    var body: some View {
        ZStack {
            Color.white.opacity(0.84)
            RadialGradient(colors: [AircColor(0x9EE6CB).alpha(0.75).color, .clear], center: UnitPoint(x: 0.18, y: 0.18), startRadius: 0, endRadius: 330)
            RadialGradient(colors: [AircColor(0xF6C5DA).alpha(0.75).color, .clear], center: UnitPoint(x: 0.85, y: 0.2), startRadius: 0, endRadius: 340)
            RadialGradient(colors: [AircColor(0xB9D4FA).alpha(0.8).color, .clear], center: UnitPoint(x: 0.28, y: 0.95), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [AircColor(0xD6C4F7).alpha(0.8).color, .clear], center: UnitPoint(x: 0.85, y: 0.92), startRadius: 0, endRadius: 320)
            AircGrainOverlay(opacity: 0.06)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 1. Welcome

struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack(alignment: .bottom) {
            AircOnboardingHero(title: "Welcome to Airc",
                               subtitle: "The calm, Arc-style browser for your Mac. Your Spaces, tabs and logins move over in about a minute.") {
                Image(nsImage: AppIconImage.image).resizable().interpolation(.high).frame(width: 128, height: 128)
                    .accessibilityLabel("Airc")
            } actions: {
                Button { model.onNext?() } label: {
                    HStack(spacing: 6) { Text("Get started"); Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)) }
                }
                .buttonStyle(.airc(.primary, size: .large))
                .keyboardShortcut(.defaultAction)
            }
            Text("Open source · Apache-2.0")
                .aircFont(AircFont.mono)
                .foregroundStyle(AircColor.black(0.38).color)
                .padding(.bottom, 26)
        }
        .aircTheme(DesignTheme.default.resolved(systemIsDark: false))
    }
}

// MARK: - 2. Bring your Arc

struct ArcStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        AircOnboardingPage(step: OnboardingStep.arc.dot, of: model.dots, title: title, subtitle: subtitle,
                           drawsBackground: false) {
            SidebarPreview(model: model)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if showsSources { ImportSourceStrip(model: model) }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .testAnchor("onboarding.content")
        } actions: {
            actions
        }
    }

    /// The picker shows once Arc's search is done (IM-4: every browser found, Arc first).
    private var showsSources: Bool {
        if case .searching = model.arc, model.source == nil { return false }
        return !model.sources.isEmpty && !model.choosing
    }

    private var title: String {
        switch model.source {
        case .browser?: "Bring your \(model.selectedSource?.name ?? "browser") with you."
        case .bookmarksFile?: "Bring your bookmarks with you."
        case .passwords?: "Bring your passwords."
        case .arc?: model.choosing ? "Choose what comes over." : "Bring your Arc with you."
        case nil:
            switch model.arc {
            case .notFound: "Start fresh."
            default: "Bring your Arc with you."
            }
        }
    }

    private var subtitle: String {
        switch model.source {
        case .browser?:
            if model.reimport?.line != nil { return "Bookmarks you brought over before update in place; new ones go after yours. Nothing in Airc is removed." }
            return "Each \(model.selectedSource?.name ?? "browser") profile becomes an Airc profile with its own Space: the bookmarks bar as pinned tabs, the rest in a folder."
        case .bookmarksFile?:
            return "Safari keeps its library to itself. Export your bookmarks from Safari, or any browser, and choose the file here."
        case .passwords?:
            return "Export them from your browser as a CSV file and choose it here. They go into the profile you pick and stay on this Mac."
        case .arc?, nil:
            switch model.arc {
            case .searching: return "Looking for Arc on this Mac…"
            case .found:
                if model.choosing { return "Pick the Spaces to bring. Their profiles and Favorites come with them." }
                if model.reimport?.line != nil { return "Spaces you brought over before update in place from Arc; new ones go after yours. Nothing in Airc is removed." }
                return "We found Arc on this Mac. Your Spaces come over exactly as they are, profiles and all."
            case .notFound(let why): return why
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.source {
        case .browser?, .bookmarksFile?: BrowserSourceDetail(model: model)
        case .passwords?: PasswordsPane(model: model, showsHeader: true)
        case .arc?:
            if model.choosing { chooser } else { summary }
        case nil:
            if case .searching = model.arc {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading Arc's sidebar").aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
                }
            } else {
                AircGroup {
                    infoRow("sparkles", "One Space to start, in its own profile", "Add more with + at the bottom of the sidebar.")
                    infoRow("person.crop.circle.badge.plus", "A profile per Space when you want one", "Each profile keeps its own logins, history and cookies.")
                }
            }
        }
    }

    private var summary: some View {
        let c = model.counts
        return VStack(alignment: .leading, spacing: 10) {
            SourceHeader(model.arcLabel, "\(c.spaces) Spaces · \(c.profiles) profiles · \(c.tabs) tabs") {
                ArcAppIcon(size: 36)
            } trailing: {
                Button("Back up first") { model.onBackUpArc?() }
                    .buttonStyle(.airc(.secondary, size: .regular))
                    .help("Zip Arc's sidebar and profile list into Documents before importing (IM-5)")
            }
            AircGroup {
                checkRow("Spaces, pinned tabs and folders", model.reimport?.line, count: c.tabs, isOn: .constant(true), enabled: false, dims: false)
                    .testAnchor("onboarding.import.spaces")
                checkRow("Favorites, per profile", nil, count: c.favorites, isOn: $model.includeFavorites)
                    .testAnchor("onboarding.import.favorites")
                checkRow("Logins and saved passwords", "macOS asks for your Mac password once.", count: nil, isOn: $model.includeLogins)
            }
            if let note = model.importNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                    .lineLimit(2)
            } else if !model.importChanges.isEmpty {
                ImportChangesLine(changes: model.importChanges)
            }
        }
    }

    private var chooser: some View {
        let spaces = model.blueprint?.spaces ?? []
        return ScrollView(.vertical, showsIndicators: false) {
            AircGroup {
                ForEach(spaces) { s in
                    let on = Binding(get: { model.chosenSpaces.contains(s.sourceID) },
                                     set: { v in if v { model.chosenSpaces.insert(s.sourceID) } else { model.chosenSpaces.remove(s.sourceID) } })
                    HStack(spacing: 12) {
                        AircCheckbox(isOn: on)
                        AircThemeDisc(theme: model.resolved(s), size: 18)
                        Text(s.emoji ?? "•").font(.system(size: 14)).frame(width: 20)
                        Text(s.name).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(model.profileRows.first { $0.id == s.profileSourceID }?.profile.name ?? model.profile(of: s)?.name ?? "")
                            .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1).fixedSize()
                        Text("\(s.pinnedTabCount)").aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextTertiary.color).frame(minWidth: 22, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                    .onTapGesture { on.wrappedValue.toggle() }
                }
            }
        }
        .frame(maxHeight: 250)
    }

    @ViewBuilder private var actions: some View {
        switch model.source {
        case .browser?, .bookmarksFile?:
            Button("Start fresh") { model.onStartFresh?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            if model.source == .bookmarksFile, model.selectedRead == nil {
                Button("Choose File…") { model.onChooseBookmarksFile?() }
                    .buttonStyle(.airc(.primary, size: .large))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.readingSource)
                    .testAnchor("onboarding.primary")
            } else {
                if model.source == .bookmarksFile {
                    Button("Other File…") { model.onChooseBookmarksFile?() }.buttonStyle(.airc(.secondary, size: .large))
                }
                Button("Import from \(model.selectedSource?.name ?? "browser")") { model.onImportEverything?() }
                    .buttonStyle(.airc(.primary, size: .large))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasPlan || model.chosenSpaces.isEmpty)
                    .testAnchor("onboarding.primary")
            }
        case .passwords?:
            Button("Start fresh") { model.onStartFresh?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            PasswordsActions(model: model)
        case .arc?:
            if model.choosing {
                Button("Back") { model.choosing = false }.buttonStyle(.airc(.plain, size: .large))
                Spacer()
                let n = model.chosenSpaces.count
                Button(n == 1 ? "Import 1 Space" : "Import \(n) Spaces") { model.onImportChosen?() }
                    .buttonStyle(.airc(.primary, size: .large))
                    .disabled(n == 0)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Start fresh") { model.onStartFresh?() }.buttonStyle(.airc(.plain, size: .large))
                Spacer()
                Button("Choose…") { model.choosing = true }.buttonStyle(.airc(.secondary, size: .large))
                Button("Import everything") { model.onImportEverything?() }
                    .buttonStyle(.airc(.primary, size: .large))
                    .keyboardShortcut(.defaultAction)
                    .testAnchor("onboarding.primary")
            }
        case nil:
            if case .searching = model.arc {
                Spacer()
                Button("Start fresh") { model.onStartFresh?() }.buttonStyle(.airc(.plain, size: .large))
            } else {
                Button("Back") { model.onBack?() }.buttonStyle(.airc(.plain, size: .large))
                Spacer()
                Button("Find Arc's folder…") { model.onLocateArc?() }.buttonStyle(.airc(.secondary, size: .large))
                Button("Continue") { model.onStartFresh?() }.buttonStyle(.airc(.primary, size: .large)).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func checkRow(_ title: String, _ subtitle: String?, count: Int?, isOn: Binding<Bool>, enabled: Bool = true, dims: Bool = true) -> some View {
        ImportCheckRow(title: title, subtitle: subtitle, count: count, isOn: isOn, enabled: enabled, dims: dims)
    }

    private func infoRow(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        ImportInfoRow(symbol: symbol, title: title, subtitle: subtitle)
    }
}

/// A row with a checkbox, a title (and a subtitle), and a count at the trailing edge.
struct ImportCheckRow: View {
    let title: String
    var subtitle: String?
    var count: Int?
    @Binding var isOn: Bool
    var enabled = true
    var dims = true
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            AircCheckbox(isOn: $isOn, isEnabled: enabled, dimsWhenDisabled: dims)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                if let subtitle {
                    Text(subtitle).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
                        .truncationMode(.tail).help(subtitle)
                }
            }
            Spacer()
            if let count { Text(count.formatted()).aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextTertiary.color) }
        }
        .padding(.horizontal, 14)
        .frame(height: subtitle == nil ? 44 : 54)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { withAircAnimation(AircSpring.toggle) { isOn.toggle() } } }
    }
}

/// A row that explains: a symbol, a title and a line under it.
struct ImportInfoRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var minHeight: CGFloat = 54
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.accent.color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                Text(subtitle).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: minHeight)
    }
}

/// The import step's header card: the source's icon, name and counts, and an action at the trailing edge.
struct SourceHeader<Icon: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    let icon: Icon
    let trailing: Trailing
    @Environment(\.aircTheme) private var theme

    init(_ title: String, _ subtitle: String, @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon()
        self.trailing = trailing()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous)
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                Text(subtitle).aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextSecondary.color)
                    .lineLimit(1).truncationMode(.tail).help(subtitle)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(shape.fill((theme.isDark ? AircColor.white(0.035).over(theme.surface) : AircColor.white()).color))
        .overlay(shape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
        .testAnchor("onboarding.source.header")
    }
}

/// IM-4: the sources the import step can bring things from, Arc first, as one row of pills. Past the card's width it
/// scrolls, with a fade at the edge, and keeps the picked one in view.
struct ImportSourceStrip: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.aircTheme) private var theme
    @State private var contentWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0

    private var overflows: Bool { contentWidth > visibleWidth + 0.5 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.sources) { pill($0).id($0.source) }
                }
                .padding(.horizontal, 1)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { contentWidth = $0 }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { visibleWidth = $0 }
            .onChange(of: model.source) { _, s in
                guard let s, overflows else { return }
                withAircAnimation(AircSpring.toggle) { proxy.scrollTo(s) }
            }
        }
        .frame(height: 30)
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(overflows ? 0 : 1)], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            }
        }
        .testAnchor("onboarding.sources")
    }

    private func pill(_ s: OnboardingModel.SourceItem) -> some View {
        let on = model.source == s.source
        return Button { withAircAnimation(AircSpring.toggle) { model.onSelectSource?(s.source) } } label: {
            HStack(spacing: 5) {
                SourceIcon(item: s, size: 16)
                Text(s.name).aircFont(AircFont.callout.weight(on ? .semibold : .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle((on ? theme.surfaceText : theme.surfaceTextSecondary).color)
            .padding(.leading, 6)
            .padding(.trailing, 9)
            .frame(height: 28)
            .background(Capsule().fill(on ? theme.surfaceSelected.color : Color.clear))
            .overlay(Capsule().inset(by: 0.25).stroke(on ? theme.surfaceBorder.color : Color.clear, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help(s))
        .accessibilityAddTraits(on ? .isSelected : [])
        .testAnchor("onboarding.source." + s.anchor)
    }

    private func help(_ s: OnboardingModel.SourceItem) -> String {
        switch s.source {
        case .arc: "Spaces, pinned tabs, Favorites and logins from Arc"
        case .browser: "Bookmarks and history from \(s.name)"
        case .bookmarksFile: "Bookmarks from a file Safari (or any browser) exports"
        case .passwords: "Saved passwords from a CSV file you export"
        }
    }
}

/// A source's icon: the installed app's (never in automated runs), else a calm stand-in in the browser's colour.
struct SourceIcon: View {
    let item: OnboardingModel.SourceItem
    let size: CGFloat

    var body: some View {
        Group {
            switch item.source {
            case .arc: ArcAppIcon(size: size)
            case .passwords: tile(AircColor(0x8E9AAF), symbol: "key.fill")
            default:
                if let icon = SourceIcon.icon(item) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else if item.kind == .safari {
                    tile(AircColor(hex: BrowserKind.safari.color) ?? AircColor(0x7FB8F0), symbol: "safari")
                } else {
                    tile(item.kind.flatMap { AircColor(hex: $0.color) } ?? AircColor(0x9AA5B8), letter: String(item.name.prefix(1)))
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func tile(_ c: AircColor, symbol: String? = nil, letter: String? = nil) -> some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [c.color, c.lerp(to: .black(), 0.18).color], startPoint: .top, endPoint: .bottom))
            .overlay {
                if let symbol { Image(systemName: symbol).font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white) }
                if let letter { Text(letter).font(.system(size: size * 0.6, weight: .bold, design: .rounded)).foregroundStyle(.white) }
            }
            .padding(size * 0.06)
    }

    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func icon(_ item: OnboardingModel.SourceItem) -> NSImage? {
        let key = item.bundleIDs.joined(separator: ",")
        if let i = cache[key] { return i }
        guard !missing.contains(key) else { return nil }
        if let i = BrowserImportLocator.icon(bundleIDs: item.bundleIDs) { cache[key] = i; return i }
        missing.insert(key)
        return nil
    }
}

/// Another browser's (or a bookmarks file's) part of the import step: its counts, each profile with its colour and
/// what it brings, ticked to come over, and its history.
struct BrowserSourceDetail: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.aircTheme) private var theme

    static let rowHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = model.selectedRead {
                header(r)
                AircGroup {
                    if model.source == .bookmarksFile {
                        ImportInfoRow(symbol: "doc.text", title: model.bookmarksFileName ?? "Bookmarks file",
                                      subtitle: "Becomes the Space “\(r.plan.spaces.first?.name ?? "Safari")”, in its own profile.", minHeight: 52)
                    } else {
                        ScrollView(.vertical, showsIndicators: r.profiles.count > 2) {
                            VStack(spacing: 0) { ForEach(r.profiles) { profileRow($0, r) } }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: Self.rowHeight * min(CGFloat(r.profiles.count), 2.5))
                        .testAnchor("onboarding.browser.profiles")
                        ImportCheckRow(title: "History, for ⌘T suggestions", subtitle: nil, count: chosenHistory(r), isOn: $model.includeHistory)
                            .testAnchor("onboarding.browser.history")
                    }
                }
                if let note = model.importNote ?? model.sourceNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(2)
                } else if !model.importChanges.isEmpty {
                    ImportChangesLine(changes: model.importChanges)
                }
            } else if model.source == .bookmarksFile {
                SourceHeader("Safari", model.readingSource ? "Reading the file…" : "Bookmarks from a file you export") {
                    SourceIcon(item: model.selectedSource ?? .init(source: .bookmarksFile, name: "Safari", kind: .safari), size: 36)
                } trailing: { EmptyView() }
                AircGroup {
                    ImportInfoRow(symbol: "square.and.arrow.up", title: "In Safari: File → Export → Bookmarks…",
                                  subtitle: "It saves “Safari Bookmarks.html”. Favorites become pinned tabs.")
                    ImportInfoRow(symbol: "doc.on.doc", title: "Any browser's bookmarks file works",
                                  subtitle: "Chrome, Edge and Firefox export the same kind of file.")
                }
                if let note = model.sourceNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(2)
                }
            } else {
                SourceHeader(model.selectedSource?.name ?? "", model.sourceNote ?? "Reading bookmarks and history…") {
                    if let s = model.selectedSource { SourceIcon(item: s, size: 36) }
                } trailing: {
                    if model.sourceNote == nil { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    /// The header's line for what's ticked: "26 bookmarks · 6 folders · 300 history entries".
    static func countsLine(_ r: BrowserImport, chosen spaces: Set<String>, history: Bool) -> String {
        let chosen = r.profiles.filter { spaces.contains(BrowserImport.Keys.space(r.installID, $0.profileID)) }
        return BrowserImportAdapter.counts(bookmarks: chosen.reduce(0) { $0 + $1.bookmarks }, folders: chosen.reduce(0) { $0 + $1.folders },
                                           history: r.fromFile || !history ? nil : chosen.reduce(0) { $0 + $1.history })
    }

    private func header(_ r: BrowserImport) -> some View {
        let line = Self.countsLine(r, chosen: model.chosenSpaces, history: model.includeHistory)
        return SourceHeader(model.source == .bookmarksFile ? (r.kind?.name ?? "Bookmarks") : (model.selectedSource?.name ?? ""), line) {
            if let s = model.selectedSource { SourceIcon(item: s, size: 36) }
        } trailing: { EmptyView() }
        .testAnchor("onboarding.browser.counts")
    }

    private func chosenHistory(_ r: BrowserImport) -> Int {
        r.profiles.filter { model.chosenSpaces.contains(BrowserImport.Keys.space(r.installID, $0.profileID)) }.reduce(0) { $0 + $1.history }
    }

    private func profileRow(_ p: BrowserProfileSummary, _ r: BrowserImport) -> some View {
        let space = BrowserImport.Keys.space(r.installID, p.profileID)
        let on = Binding(get: { model.chosenSpaces.contains(space) },
                         set: { v in if v { model.chosenSpaces.insert(space) } else { model.chosenSpaces.remove(space) } })
        let color = p.color.flatMap { AircColor(hex: $0) } ?? r.kind.flatMap { AircColor(hex: $0.color) } ?? theme.accent
        return HStack(spacing: 12) {
            AircCheckbox(isOn: on)
            AircProfileAvatar(AircProfileIdentity(name: p.name, color: color), size: 22)
            Text(p.name).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(1)
            Spacer(minLength: 8)
            Text(p.unreadable.contains("bookmarks") ? "bookmarks unreadable"
                 : BrowserImportAdapter.counts(bookmarks: p.bookmarks, folders: p.folders, history: nil))
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { withAircAnimation(AircSpring.toggle) { on.wrappedValue.toggle() } }
        .onHover { model.hover(profile: p.sourceKey, inside: $0) }
        .testAnchor("onboarding.browser.profile.\(p.profileID)")
    }
}

/// Passwords from a CSV file (IM-4): which profile they go into, where to export them from, and once read what came
/// over, with the offer to move the plain-text file to the Trash. On the import step (its Passwords source) and on the
/// logins step after another browser's import.
struct PasswordsPane: View {
    @ObservedObject var model: OnboardingModel
    var showsHeader: Bool
    var kind: BrowserKind? = nil
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                SourceHeader("Passwords", "From a CSV file you export") {
                    SourceIcon(item: .init(source: .passwords, name: "Passwords", kind: nil), size: 36)
                } trailing: { EmptyView() }
            }
            AircGroup {
                switch model.passwords {
                case .done(let o):
                    ImportInfoRow(symbol: o.isFailure || o.nothingIn ? "exclamationmark.triangle" : "checkmark.circle.fill", title: o.summary,
                                  subtitle: o.details ?? (o.nothingIn ? "The file had no passwords Airc could bring over."
                                                          : "Into \(profileName). Saved here, re-encrypted with Airc's own key."),
                                  minHeight: 52)
                        .testAnchor("onboarding.passwords.result")
                    discardRow(o)
                default:
                    intoRow
                    if model.loginsAvailable {
                        ImportInfoRow(symbol: "square.and.arrow.up", title: "Export the file from your browser",
                                      subtitle: PasswordImport.exportHint(kind), minHeight: 52)
                        ImportInfoRow(symbol: "lock", title: "Plain text until it's in",
                                      subtitle: "Airc offers to move it to the Trash once it's in.", minHeight: 52)
                    } else {
                        ImportInfoRow(symbol: "lock", title: "Comes with the Chromium engine",
                                      subtitle: "This build runs on WebKit, so no file is read.", minHeight: 52)
                    }
                }
            }
            switch model.passwords {
            case .reading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Bringing over passwords…").aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle")
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(2)
                    .testAnchor("onboarding.passwords.failed")
            default: EmptyView()
            }
        }
    }

    private var profileName: String { model.aircProfiles.first { $0.id == model.passwordsProfile }?.name ?? "this profile" }

    private var intoRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(theme.accent.color).frame(width: 20)
            Text("Into the profile").aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
            Spacer()
            Menu {
                ForEach(model.aircProfiles, id: \.id) { p in
                    Button(p.name) { model.passwordsProfile = p.id }
                }
            } label: {
                Text(profileName).aircFont(AircFont.body.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .testAnchor("onboarding.passwords.profile")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    /// The plain-text file: the offer to move it to the Trash once its passwords are in Airc; otherwise only what
    /// happened to it (nothing came over: it stays, the only copy of what's in it besides the browser's).
    @ViewBuilder private func discardRow(_ o: PasswordImport.Outcome) -> some View {
        let advice = o.fileAdvice
        HStack(spacing: 12) {
            Image(systemName: advice.offersTrash ? "trash" : "doc.text").font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.accent.color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.passwordsFileDiscarded == true ? "Moved to the Trash" : "“\(model.passwordsFileName ?? "The file")” is plain text")
                    .aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).lineLimit(1).truncationMode(.middle)
                Text(model.passwordsFileDiscarded == true ? "Empty the Trash to delete it for good."
                     : model.passwordsFileDiscarded == false ? "It couldn't be moved. Delete it yourself."
                     : advice.text)
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
            }
            Spacer(minLength: 8)
            if advice.offersTrash && model.passwordsFileDiscarded != true {
                Button("Move to Trash") { model.onDiscardPasswordsFile?() }
                    .buttonStyle(.airc(.secondary, size: .regular))
                    .testAnchor("onboarding.passwords.trash")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }
}

/// The passwords pane's buttons: choose the file, then Done.
struct PasswordsActions: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        switch model.passwords {
        case .done:
            Button("Done") { model.onPasswordsDone?() }
                .buttonStyle(.airc(.primary, size: .large))
                .keyboardShortcut(.defaultAction)
                .testAnchor("onboarding.primary")
        case .reading:
            Button("Importing…") {}.buttonStyle(.airc(.primary, size: .large)).disabled(true)
        default:
            Button("Choose CSV File…") { model.onChoosePasswordsFile?() }
                .buttonStyle(.airc(.primary, size: .large))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.loginsAvailable)
                .testAnchor("onboarding.primary")
        }
    }
}

/// Arc's app icon when Arc is installed (and this isn't an automated run); otherwise a neutral stand-in.
struct ArcAppIcon: View {
    var size: CGFloat = 42

    var body: some View {
        Group {
            if let icon = ArcAppIcon.installedIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.214, style: .continuous)
                    .fill(LinearGradient(colors: [AircColor(0xF7B184).color, AircColor(0xE0559F).color], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Image(systemName: "arrow.down.forward.and.arrow.up.backward").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.white))
                    .padding(size * 0.07)
            }
        }
        .frame(width: size, height: size)
    }

    static let installedIcon: NSImage? = {
        guard !LaunchOptions.current.isAutomated, FileManager.default.fileExists(atPath: "/Applications/Arc.app") else { return nil }
        return NSWorkspace.shared.icon(forFile: "/Applications/Arc.app")
    }()
}

// MARK: - 3. Spaces and accounts

struct AccountsStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.aircTheme) private var theme

    /// Every row is this tall, signed in or not, so hovering or signing in never moves a row.
    static let rowHeight: CGFloat = 64

    var body: some View {
        AircOnboardingPage(step: OnboardingStep.accounts.dot, of: model.dots, title: "Spaces and accounts.",
                           subtitle: "Each \(model.importedName) profile becomes a real profile with its own logins. Sign each one in to its own Google account.",
                           drawsBackground: false) {
            SidebarPreview(model: model)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                // Every profile, scrolling past the room there is; a fade at the bottom says there's more.
                ScrollView(.vertical, showsIndicators: true) {
                    AircGroup {
                        ForEach(model.profileRows) { row in
                            profileRow(row)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(overflows ? 0 : 1)], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .testAnchor("onboarding.accounts.list")
                if model.offersLoginsStep {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.surfaceTextTertiary.color)
                        Text(!model.loginsAvailable ? "Logins come over with the Chromium engine."
                             : model.importedFromArc ? "Next, macOS asks for your Mac password once, to unlock Arc's saved logins."
                             : "Next: saved passwords, from a CSV file you export from \(model.importedName).")
                            .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .testAnchor("onboarding.content")
        } actions: {
            Button("Back") { model.onBack?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            if model.offersLoginsStep && model.loginsAvailable {
                Button(model.importedFromArc ? "Skip logins" : "Skip passwords") { model.onSkipLogins?() }.buttonStyle(.airc(.secondary, size: .large))
            }
            Button("Continue") { model.onNext?() }.buttonStyle(.airc(.primary, size: .large)).keyboardShortcut(.defaultAction)
                .testAnchor("onboarding.primary")
        }
    }

    /// More rows than the list shows at once (with the logins note under it).
    private var overflows: Bool { CGFloat(model.profileRows.count) * Self.rowHeight > 230 }

    private func profileRow(_ row: OnboardingModel.ProfileRow) -> some View {
        let p = row.profile
        let account = model.accounts[p.sourceID]
        let color = p.color?.aircColor ?? theme.accent
        let photo = account == nil ? nil : model.accountPhotos[p.sourceID]
        return HStack(spacing: 12) {
            AircProfileAvatar(AircProfileIdentity(name: p.name, emoji: p.emoji, color: color, photo: photo, account: account?.email), size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(p.name).aircFont(AircFont.body.weight(.medium)).foregroundStyle(theme.surfaceText.color)
                        .lineLimit(1).layoutPriority(1)
                    ForEach(row.spaces.prefix(2)) { s in
                        AircSpaceChip(emoji: s.emoji, name: ThemeStep.chipName(s.name, max: 14), compact: true).fixedSize().help(s.name)
                    }
                    if row.spaces.count > 2 {
                        Text("+\(row.spaces.count - 2)").aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color).fixedSize()
                    }
                }
                .frame(height: 22)
                accountLine(p, account)
                    .frame(height: 16)
            }
            Spacer(minLength: 8)
            accountButton(p, signedIn: account != nil)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onHover { model.hover(profile: p.sourceID, inside: $0) }
        .testAnchor("onboarding.account.\(p.sourceID)")
    }

    /// "Signed in as alex@example.com" (the name in its tooltip), "Checking Google sign-in…" or "Not signed in to Google".
    @ViewBuilder private func accountLine(_ p: ImportBlueprint.Profile, _ account: GoogleAccount?) -> some View {
        if let account {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent.color)
                (Text("Signed in as ").foregroundStyle(theme.surfaceTextSecondary.color)
                 + Text(account.email).foregroundStyle(theme.surfaceText.color))
                    .aircFont(AircFont.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help("Signed in to Google as " + (account.name.map { "\($0) (\(account.email))" } ?? account.email))
            .testAnchor("onboarding.account.signedIn.\(p.sourceID)")
        } else if model.checkingAccounts.contains(p.sourceID) {
            Text("Checking Google sign-in…").aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1)
        } else {
            Text("Not signed in to Google").aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1)
        }
    }

    @ViewBuilder private func accountButton(_ p: ImportBlueprint.Profile, signedIn: Bool) -> some View {
        let busy = model.signingIn == p.sourceID
        if signedIn {
            Button(busy ? "Switching…" : "Switch…") { model.onSwitchAccount?(p.sourceID) }
                .buttonStyle(.airc(.secondary, size: .small))
                .disabled(model.signingIn != nil)
                .help("Sign the \(p.name) profile in to another Google account")
        } else {
            Button { model.onSignIn?(p.sourceID) } label: {
                HStack(spacing: 6) {
                    GoogleG().frame(width: 12, height: 12)
                    Text(busy ? "Signing in…" : "Sign in")
                }
            }
            .buttonStyle(.airc(.secondary, size: .small))
            .disabled(model.signingIn != nil || model.checkingAccounts.contains(p.sourceID))
            .help("Opens Google's sign-in page in the \(p.name) profile")
        }
    }
}

/// What the import changes on the way, one line ("1 Easel was left out · 1 live folder is now a plain folder") and a
/// Details popover that says why for each (IM-1). Never names a title or address: the warnings don't carry them.
struct ImportChangesLine: View {
    let changes: [ImportAdapter.Change]
    @Environment(\.aircTheme) private var theme
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.surfaceTextTertiary.color)
            Text(changes.prefix(2).map(\.summary).joined(separator: " · ") + (changes.count > 2 ? " · \(changes.count - 2) more" : ""))
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .lineLimit(1).truncationMode(.tail)
            Button("Details") { showsDetails.toggle() }
                .buttonStyle(.plain)
                .aircFont(AircFont.callout.weight(.medium))
                .foregroundStyle(theme.accent.color)
                .fixedSize()
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details }
                .testAnchor("onboarding.import.details")
        }
        .frame(height: 18)
        .testAnchor("onboarding.import.changes")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What changes on the way").aircFont(AircFont.body.weight(.semibold))
            ForEach(changes) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.summary).aircFont(AircFont.body.weight(.medium))
                    Text(c.detail).aircFont(AircFont.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}

/// Google's "G", drawn from four arcs in its colours (no bitmap from Google).
struct GoogleG: View {
    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height)
            let line = w * 0.22
            ZStack {
                // Angles clockwise from 3 o'clock; the G opens between 315° and 0°.
                arc(0, 50, AircColor(0x4285F4), line)
                arc(50, 140, AircColor(0x34A853), line)
                arc(140, 215, AircColor(0xFBBC05), line)
                arc(215, 315, AircColor(0xEA4335), line)
                Rectangle().fill(AircColor(0x4285F4).color).frame(width: w * 0.42, height: line).offset(x: w * 0.21 - line / 4)
            }
            .frame(width: w, height: w)
        }
    }

    private func arc(_ from: Double, _ to: Double, _ c: AircColor, _ line: CGFloat) -> some View {
        Circle().trim(from: from / 360, to: to / 360)
            .stroke(c.color, style: StrokeStyle(lineWidth: line))
            .padding(line / 2)
    }
}

// MARK: - 3b. Logins (the Keychain explainer, spec 2a)

struct LoginsStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        if model.importedFromArc { arc } else { passwords }
    }

    /// After another browser's import: its saved passwords, from a CSV file it exports (IM-4). Its own password store
    /// is never read.
    private var passwords: some View {
        AircOnboardingPage(step: OnboardingStep.logins.dot, of: model.dots, title: "Bring your passwords.",
                           subtitle: "\(model.importedName) keeps saved passwords to itself. Export them as a CSV file and choose it here; they go into the profile you pick.",
                           drawsBackground: false) {
            SidebarPreview(model: model)
        } content: {
            PasswordsPane(model: model, showsHeader: false, kind: model.selectedRead?.kind ?? model.selectedSource?.kind)
                .frame(maxWidth: .infinity, alignment: .leading)
                .testAnchor("onboarding.content")
        } actions: {
            Button("Back") { model.onBack?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            switch model.passwords {
            case .done, .reading: PasswordsActions(model: model)
            default:
                Button("Not now") { model.onSkipLogins?() }.buttonStyle(.airc(.secondary, size: .large))
                PasswordsActions(model: model)
            }
        }
    }

    private var arc: some View {
        AircOnboardingPage(step: OnboardingStep.logins.dot, of: model.dots, title: "Bring your logins.",
                           subtitle: model.loginsAvailable
                               ? "Arc keeps passwords and cookies locked with a key in your Keychain. macOS asks for your Mac password once to unlock it."
                               : "Arc keeps passwords and cookies locked with a key in your Keychain. They come over once Airc runs on its Chromium engine.",
                           drawsBackground: false) {
            SidebarPreview(model: model)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if case .done(let o) = model.logins {
                    // Once read: what happened to each login and each site's cookies (engine pass 8 per-row results).
                    status
                    ImportResultsView(outcome: o, profileNames: model.profileNames, maxHeight: 200)
                } else {
                AircGroup {
                    row("key", "Saved passwords", "Every Arc profile's, into the matching Airc profile.")
                    row("checkmark.shield", "Cookies", "So you stay signed in where Arc had you signed in.")
                    if model.loginsAvailable {
                        row("lock", "Stays on this Mac", "Read even while Arc is open, and re-encrypted here with Airc's own key. Nothing is sent anywhere.")
                    } else {
                        row("lock", "Comes with the Chromium engine", "This build runs on WebKit, so nothing is read.")
                    }
                }
                status
                }
            }
        } actions: {
            Button("Back") { model.onBack?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            switch model.logins {
            case _ where !model.loginsAvailable:
                Button("Continue") { model.onSkipLogins?() }.buttonStyle(.airc(.primary, size: .large)).keyboardShortcut(.defaultAction)
            case .done, .failed:
                Button("Continue") { model.onNext?() }.buttonStyle(.airc(.primary, size: .large)).keyboardShortcut(.defaultAction)
            case .reading:
                Button("Importing…") {}.buttonStyle(.airc(.primary, size: .large)).disabled(true)
            default:
                Button("Not now") { model.onSkipLogins?() }.buttonStyle(.airc(.secondary, size: .large))
                Button("Import logins") { model.onImportLogins?() }.buttonStyle(.airc(.primary, size: .large)).keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.logins {
        case .reading(let p):
            HStack(spacing: 10) {
                ProgressView(value: p).progressViewStyle(.linear).tint(theme.accent.color).frame(width: 160)
                Text("Reading logins…").aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
            }
        case .done(let o):
            Label(o.summary, systemImage: o.isFailure ? "exclamationmark.triangle" : "checkmark.circle.fill")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private func row(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.accent.color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                Text(subtitle).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
    }
}

// MARK: - 4. Make it yours

struct ThemeStep: View {
    @ObservedObject var model: OnboardingModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        AircOnboardingPage(step: OnboardingStep.theme.dot, of: model.dots,
                           title: model.importedSource == .arc && !model.startedFresh ? "Looks right?" : "Make it yours.",
                           subtitle: "Pick a colour for each Space. The window re-tints as you choose.",
                           drawsBackground: false) {
            SidebarPreview(model: model)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if model.previewSpaces.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(model.previewSpaces.enumerated()), id: \.element.sourceID) { i, s in
                                AircSpaceChip(emoji: s.emoji, name: Self.chipName(s.name), selected: i == model.focusedSpace)
                                    .help(s.name)
                                    .onTapGesture { model.focusedSpace = i; model.onThemeChange?() }
                            }
                        }
                        .padding(2)
                    }
                    // More chips than fit: they fade out at the card's edge and scroll.
                    .mask(AircFadeMask(fade: 28))
                }
                presets
                labeled("Appearance") {
                    AircSegmented(selection: appearance, segments: [
                        .init(value: .auto, title: "Auto", symbol: "sparkles"),
                        .init(value: .light, title: "Light", symbol: "sun.max"),
                        .init(value: .dark, title: "Dark", symbol: "moon"),
                    ])
                }
                labeled("Intensity") { AircSlider(value: intensity) }
                labeled("Translucency") {
                    AircSegmented(selection: $model.translucency, segments: AircTranslucency.allCases.map { .init(value: $0, title: $0.title) })
                }
            }
        } actions: {
            Button("Back") { model.onBack?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            Button(model.importedSource == .arc && !model.startedFresh ? "Looks right" : "Continue") { model.onNext?() }
                .buttonStyle(.airc(.primary, size: .large))
                .keyboardShortcut(.defaultAction)
        }
    }

    /// A chip in a scrolling row has all the width it asks for, so a long name is shortened here.
    static func chipName(_ name: String, max: Int = 24) -> String {
        name.count > max ? String(name.prefix(max - 2)).trimmingCharacters(in: .whitespaces) + "…" : name
    }

    private var current: SpaceTheme { model.theme(of: model.focused) }

    private func set(_ change: (inout SpaceTheme) -> Void) {
        var t = current
        change(&t)
        model.themes[model.focused.sourceID] = t
        model.onThemeChange?()
    }

    private var appearance: Binding<Appearance> {
        Binding(get: { current.appearance }, set: { v in set { $0.appearance = v } })
    }

    private var intensity: Binding<Double> {
        Binding(get: { current.intensity }, set: { v in set { $0.intensity = v } })
    }

    private var presets: some View {
        let presets = DesignTheme.presets
        let columns = Array(repeating: GridItem(.fixed(46), spacing: 10), count: 6)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(presets) { p in
                let t = p.theme.model
                let selected = current.colors == t.colors && current.grain == t.grain
                AircThemeDisc(theme: p.theme.resolved(systemIsDark: model.systemDark), selected: selected, size: 40)
                    .help(p.name)
                    .onTapGesture {
                        set { $0.colors = t.colors; $0.grain = t.grain; $0.appearance = t.appearance }
                    }
            }
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 14) {
            Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color).frame(width: 96, alignment: .leading)
            content()
        }
    }
}

// MARK: - 5. Default browser

/// One calm sentence, a picture of the macOS confirmation it leads to (research note: explain every OS prompt before it
/// appears), and Make Default / Not now. Skipped when Airc already is the default.
struct DefaultBrowserStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        AircOnboardingPage(step: OnboardingStep.defaultBrowser.dot, of: model.dots, title: "Make Airc your default?",
                           subtitle: "Arc goes dark on Dec 22, so links from Mail and Slack should open here. macOS will ask you to confirm.",
                           drawsBackground: false) {
            SidebarPreview(model: model)
        } content: {
            DefaultBrowserDialogPicture(current: model.currentBrowser)
        } actions: {
            Button("Back") { model.onBack?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            Button("Not now") { model.onDefaultNotNow?() }.buttonStyle(.airc(.secondary, size: .large))
            Button(model.askingDefault ? "Waiting for macOS…" : "Make Default") { model.onMakeDefault?() }
                .buttonStyle(.airc(.primary, size: .large))
                .disabled(model.askingDefault)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// macOS's confirmation as a small picture on a soft backdrop: the icon, its question and its two buttons. Not
/// interactive; the real one comes from macOS.
struct DefaultBrowserDialogPicture: View {
    let current: String
    @Environment(\.aircTheme) private var theme

    var body: some View {
        let backdrop = RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous)
        let dialog = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let dark = theme.isDark
        VStack(spacing: 0) {
            Image(nsImage: AppIconImage.image).resizable().interpolation(.high).frame(width: 52, height: 52)
            Text("Do you want to change your default web browser to “Airc” or keep using “\(current)”?")
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle((dark ? AircColor.white(0.92) : AircColor.black(0.86)).color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            VStack(spacing: 6) {
                pill("Use “Airc”", prominent: true, dark: dark)
                pill("Keep “\(current)”", prominent: false, dark: dark)
            }
            .padding(.top, 14)
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 16, trailing: 18))
        .frame(width: 244)
        .background(dialog.fill((dark ? AircColor(0x2C2C2E) : AircColor.white()).color).aircShadow(.popover))
        .overlay(dialog.inset(by: 0.25).stroke((dark ? AircColor.white(0.10) : AircColor.black(0.08)).color, lineWidth: 0.5))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(backdrop.fill((dark ? AircColor.white(0.035) : AircColor.black(0.035)).color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("macOS will ask: use Airc, or keep \(current)")
    }

    private func pill(_ title: String, prominent: Bool, dark: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : (dark ? AircColor.white(0.9) : AircColor.black(0.85)).color)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Capsule().fill(prominent ? Color(nsColor: .controlAccentColor) : (dark ? AircColor.white(0.12) : AircColor.black(0.07)).color))
    }
}

// MARK: - 6. Done: the member card

struct DoneStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        AircOnboardingHero(title: model.memberName.isEmpty ? "Welcome to Airc." : "Welcome to Airc, \(model.memberName).",
                           subtitle: subtitle) {
            MemberCard(model: model).padding(.bottom, 4)
        } actions: {
            Button { model.onShareCard?() } label: {
                HStack(spacing: 6) { Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold)); Text("Share card") }
            }
            .buttonStyle(.airc(.secondary, size: .large))
            Button("Open Airc") { model.onOpen?() }
                .buttonStyle(.airc(.primary, size: .large))
                .keyboardShortcut(.defaultAction)
        }
        .overlay(alignment: .bottom) { UsageDataNote() }
    }

    private var subtitle: String {
        if model.startedFresh { return "Here's your card. Your first Space is ready." }
        if case .done(let o) = model.passwords, o.imported > 0 { return "Here's your card. Your Spaces, bookmarks and passwords are ready." }
        if !model.importedFromArc { return "Here's your card. Your Spaces and bookmarks are ready." }
        switch model.logins {
        case .done(let o) where !o.isFailure: return "Here's your card. Your Spaces, tabs and logins are ready."
        default: return "Here's your card. Your Spaces and tabs are ready."
        }
    }
}

/// The member card (Arc's had one; design §7): holographic, wearing the app icon, with the name, the date, a title
/// from the choices made and the Space emojis. Tilted slightly.
struct MemberCard: View {
    @ObservedObject var model: OnboardingModel
    var tilt = true

    static let size = CGSize(width: 360, height: 214)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [
                .init(color: AircColor(0x7FD8C4).color, location: 0),
                .init(color: AircColor(0x4F8BEA).color, location: 0.38),
                .init(color: AircColor(0x5B63EE).color, location: 0.62),
                .init(color: AircColor(0xA35BEA).color, location: 0.86),
                .init(color: AircColor(0xE25FA8).color, location: 1),
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            AircGrainOverlay(opacity: 0.22)
            LinearGradient(colors: [.white.opacity(0.22), .clear, .white.opacity(0.08)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(nsImage: AppIconImage.image).resizable().interpolation(.high).frame(width: 46, height: 46)
                        .padding(-4)
                    Spacer()
                    Text(String(format: "No. %03d %03d", model.memberNumber / 1000, model.memberNumber % 1000))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                Text(model.memberName.isEmpty ? "Member" : model.memberName)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(.white)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Member since " + model.today.formatted(.dateTime.day().month(.abbreviated).year()))
                        Text(model.memberTitle)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    Spacer()
                    Text(model.spaceEmojis.prefix(6).joined(separator: " ")).font(.system(size: 13))
                }
                .padding(.top, 6)
            }
            .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay(shape.inset(by: 0.5).stroke(.white.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 14)
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .rotationEffect(.degrees(tilt ? -2 : 0))
        .accessibilityElement(children: .combine)
    }
}
