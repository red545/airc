// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
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
            content
        } actions: {
            actions
        }
    }

    private var title: String {
        switch model.arc {
        case .notFound: "Start fresh."
        default: model.choosing ? "Choose what comes over." : "Bring your Arc with you."
        }
    }

    private var subtitle: String {
        switch model.arc {
        case .searching: "Looking for Arc on this Mac…"
        case .found: model.choosing ? "Pick the Spaces to bring. Their profiles and Favorites come with them."
            : "We found Arc on this Mac. Your Spaces come over exactly as they are, profiles and all."
        case .notFound(let why): why
        }
    }

    @ViewBuilder private var content: some View {
        switch model.arc {
        case .searching:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading Arc's sidebar").aircFont(AircFont.body).foregroundStyle(theme.surfaceTextSecondary.color)
            }
        case .notFound:
            AircGroup {
                infoRow("sparkles", "One Space to start, in its own profile", "Add more with + at the bottom of the sidebar.")
                infoRow("person.crop.circle.badge.plus", "A profile per Space when you want one", "Each profile keeps its own logins, history and cookies.")
            }
        case .found:
            if model.choosing { chooser } else { summary }
        }
    }

    private var summary: some View {
        let c = model.counts
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ArcAppIcon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.arcLabel).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                    Text("\(c.spaces) Spaces · \(c.profiles) profiles · \(c.tabs) tabs").aircFont(AircFont.mono)
                        .foregroundStyle(theme.surfaceTextSecondary.color)
                }
                Spacer()
                Button("Back up first") { model.onBackUpArc?() }
                    .buttonStyle(.airc(.secondary, size: .regular))
                    .help("Zip Arc's sidebar and profile list into Documents before importing (IM-5)")
            }
            .padding(14)
            .background(groupShape.fill(groupFill))
            .overlay(groupShape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
            AircGroup {
                checkRow("Spaces, pinned tabs and folders", nil, count: c.tabs, isOn: .constant(true), enabled: false, dims: false)
                checkRow("Favorites, per profile", nil, count: c.favorites, isOn: $model.includeFavorites)
                checkRow("Logins and saved passwords", "macOS asks for your Mac password once.", count: nil, isOn: $model.includeLogins)
            }
            if let note = model.importNote {
                Label(note, systemImage: "info.circle")
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
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
                        Text(s.emoji ?? "•").font(.system(size: 14))
                        Text(s.name).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                        Spacer()
                        Text(model.profile(of: s)?.name ?? "").aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
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
        switch model.arc {
        case .searching:
            Spacer()
            Button("Start fresh") { model.onStartFresh?() }.buttonStyle(.airc(.plain, size: .large))
        case .notFound:
            Button("Back") { model.onBack?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            Button("Find Arc's folder…") { model.onLocateArc?() }.buttonStyle(.airc(.secondary, size: .large))
            Button("Continue") { model.onStartFresh?() }.buttonStyle(.airc(.primary, size: .large)).keyboardShortcut(.defaultAction)
        case .found:
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
            }
        }
    }

    private var groupShape: RoundedRectangle { RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous) }
    private var groupFill: Color { (theme.isDark ? AircColor.white(0.035).over(theme.surface) : AircColor.white()).color }

    private func checkRow(_ title: String, _ subtitle: String?, count: Int?, isOn: Binding<Bool>, enabled: Bool = true, dims: Bool = true) -> some View {
        HStack(spacing: 12) {
            AircCheckbox(isOn: isOn, isEnabled: enabled, dimsWhenDisabled: dims)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                if let subtitle { Text(subtitle).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color) }
            }
            Spacer()
            if let count { Text(count.formatted()).aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextTertiary.color) }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: subtitle == nil ? 44 : 54)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { withAircAnimation(AircSpring.toggle) { isOn.wrappedValue.toggle() } } }
    }

    private func infoRow(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.accent.color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                Text(subtitle).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
    }
}

/// Arc's app icon when Arc is installed (and this isn't an automated run); otherwise a neutral stand-in.
struct ArcAppIcon: View {
    var body: some View {
        Group {
            if let icon = ArcAppIcon.installedIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [AircColor(0xF7B184).color, AircColor(0xE0559F).color], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Image(systemName: "arrow.down.forward.and.arrow.up.backward").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                    .padding(3)
            }
        }
        .frame(width: 42, height: 42)
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

    var body: some View {
        AircOnboardingPage(step: OnboardingStep.accounts.dot, of: model.dots, title: "Spaces and accounts.",
                           subtitle: "Each Arc profile becomes a real profile with its own logins. Sign each one in to its own Google account.",
                           drawsBackground: false) {
            SidebarPreview(model: model)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.vertical, showsIndicators: false) {
                    AircGroup {
                        ForEach(model.profileRows, id: \.profile.sourceID) { row in
                            profileRow(row.profile, row.spaces)
                        }
                    }
                }
                .frame(maxHeight: 236)
                if model.includeLogins {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.surfaceTextTertiary.color)
                        Text(model.loginsAvailable ? "Next, macOS asks for your Mac password once, to unlock Arc's saved logins."
                                                   : "Logins come over with the Chromium engine.")
                            .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                }
            }
        } actions: {
            Button("Back") { model.onBack?() }.buttonStyle(.airc(.plain, size: .large))
            Spacer()
            if model.includeLogins && model.loginsAvailable {
                Button("Skip logins") { model.onSkipLogins?() }.buttonStyle(.airc(.secondary, size: .large))
            }
            Button("Continue") { model.onNext?() }.buttonStyle(.airc(.primary, size: .large)).keyboardShortcut(.defaultAction)
        }
    }

    private func profileRow(_ p: ImportBlueprint.Profile, _ spaces: [ImportBlueprint.Space]) -> some View {
        HStack(spacing: 12) {
            AircProfileAvatar(emoji: p.emoji, name: p.name, color: p.color?.aircColor ?? theme.accent, size: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(p.name).aircFont(AircFont.body.weight(.medium)).foregroundStyle(theme.surfaceText.color)
                HStack(spacing: 5) {
                    ForEach(spaces.prefix(3)) { s in
                        AircSpaceChip(emoji: s.emoji, name: s.name, compact: true)
                    }
                    if spaces.count > 3 {
                        Text("+\(spaces.count - 3)").aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                    }
                }
            }
            Spacer(minLength: 8)
            if let account = model.accounts[p.sourceID] {
                HStack(spacing: 6) {
                    AircProfileAvatar(emoji: "", name: account, color: p.color?.aircColor ?? theme.accent, size: 18)
                    Text(account).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
                }
            } else {
                Button { model.onSignIn?(p.sourceID) } label: {
                    HStack(spacing: 6) {
                        GoogleG().frame(width: 12, height: 12)
                        Text(model.signingIn == p.sourceID ? "Signing in…" : "Sign in")
                    }
                }
                .buttonStyle(.airc(.secondary, size: .small))
                .disabled(model.signingIn != nil)
                .help("Opens Google's sign-in page in the \(p.name) profile")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { inside in
            model.hoveredProfile = inside ? p.sourceID : (model.hoveredProfile == p.sourceID ? nil : model.hoveredProfile)
            if inside, let i = model.previewSpaces.firstIndex(where: { $0.profileSourceID == p.sourceID }) { model.focusedSpace = i }
        }
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
                           title: model.hasArc && !model.startedFresh ? "Looks right?" : "Make it yours.",
                           subtitle: "Pick a colour for each Space. The window re-tints as you choose.",
                           drawsBackground: false) {
            SidebarPreview(model: model)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                if model.previewSpaces.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(model.previewSpaces.enumerated()), id: \.element.sourceID) { i, s in
                                AircSpaceChip(emoji: s.emoji, name: s.name,
                                          selected: i == model.focusedSpace)
                                    .onTapGesture { model.focusedSpace = i; model.onThemeChange?() }
                            }
                        }
                        .padding(2)
                    }
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
            Button(model.hasArc && !model.startedFresh ? "Looks right" : "Continue") { model.onNext?() }
                .buttonStyle(.airc(.primary, size: .large))
                .keyboardShortcut(.defaultAction)
        }
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
