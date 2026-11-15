// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// whatsnew2 (owner feedback, 2026-11-14: "Tab page or browser relaunch after updates should tell me what happened. I
/// have no idea what the instant Command Bar does or what 'more app icons' does"): the "What's New in Airc" tab.
///
/// After an update (Settings › General › Automatic Updates › After an update: Open a What's new tab, the default), the
/// front window opens a Today tab at `airc://whats-new?from=<last version>&to=<running>` (AircKit's WhatsNewURL). Like a
/// note's, the tab has no engine page: this native page goes in the page card, so it works offline and looks the same
/// on both engines. For every highlight of the versions since the last one seen (merged, newest first) it shows the
/// title, one or two plain sentences on what it does (`detail`), where to find it with a "Show me" / "Try it" button
/// (`action`, AircKit's WhatsNewAction: a closed list of safe in-app actions) and a bundled picture if the release has
/// one (Contents/Resources/WhatsNew/<image>.heic). The full changelog is linked at the bottom. The sidebar's card (Show a
/// small card) opens this tab too.
final class WhatsNewPage: CardDocument {
    let tabID: String
    let model: WhatsNewPageModel
    let host: WhatsNewPageView

    init(tabID: String, content: WhatsNewPageContent?, theme: ResolvedTheme) {
        self.tabID = tabID
        model = WhatsNewPageModel(content: content, theme: theme)
        host = WhatsNewPageView(model: model)
    }

    var cardView: NSView { host }

    func focus() { host.window?.makeFirstResponder(host) }

    func prepare(for c: WindowController) {
        model.controller = c
        model.theme = c.currentPalette.resolved
        host.cornerRadius = c.card.cornerRadius
        host.applyTheme()
    }

    // MARK: The pages, one per tab

    private static var pages: [String: WhatsNewPage] = [:]

    /// The page for `tabID` (made on first show); nil for another tab.
    static func page(forTab tabID: String, store: SpacesStore, theme: ResolvedTheme) -> WhatsNewPage? {
        guard let url = store.tab(tabID)?.url, WhatsNewURL.isPage(url) else { return nil }
        pages = pages.filter { store.tab($0.key) != nil }
        if let p = pages[tabID] { return p }
        let p = WhatsNewPage(tabID: tabID, content: WhatsNewCenter.shared.pageContent(url), theme: theme)
        pages[tabID] = p
        return p
    }

    static func existing(_ tabID: String?) -> WhatsNewPage? { tabID.flatMap { pages[$0] } }
}

/// The page's state: what it lists, its colours, and the window whose Settings, Command Bar or Library its buttons use.
final class WhatsNewPageModel: ObservableObject {
    @Published var content: WhatsNewPageContent?
    @Published var theme: ResolvedTheme
    /// A highlight's id to scroll to (the checks; a link to one line).
    @Published var scrollTarget: String?
    weak var controller: WindowController?
    #if AIRC_TESTING
    /// What the buttons did, in order (the checks read it).
    private(set) var performed: [String] = []
    #endif

    init(content: WhatsNewPageContent?, theme: ResolvedTheme) {
        self.content = content
        self.theme = theme
    }

    static func id(_ version: String, _ h: WhatsNewHighlight) -> String { "\(version):\(h.title)" }
    static let footerID = "whatsnew.footer"

    func perform(_ action: WhatsNewAction) {
        guard let c = controller else { return }
        UpdateCenter.shared.log("what's new tab: \(action.rawValue)")
        #if AIRC_TESTING
        performed.append(action.rawValue)
        #endif
        WhatsNewActions.perform(action, in: c)
    }

    func openChangelog() {
        guard let c = controller else { return }
        let base = ParityCommandCatalog.releaseNotes
        var url = base
        if let v = content?.version, var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            comps.fragment = "v\(v)"
            url = comps.url ?? base
        }
        UpdateCenter.shared.log("what's new tab: changelog \(url.absoluteString)")
        #if AIRC_TESTING
        performed.append("changelog")
        #endif
        c.openHelpPage(url)
    }

    func openSettings() {
        #if AIRC_TESTING
        performed.append("settingsWhatsNew")
        #endif
        WhatsNewActions.perform(.settingsUpdates, in: controller)
    }

    /// A bundled picture (nil when the name has none: the line shows without one).
    func image(_ name: String?) -> NSImage? {
        guard let name else { return nil }
        if let cached = Self.images[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "heic", subdirectory: "WhatsNew"),
              let img = NSImage(contentsOf: url) else { return nil }
        Self.images[name] = img
        return img
    }

    private static var images: [String: NSImage] = [:]
}

/// What a "Show me" / "Try it" button does: it only opens something; it never changes a setting or loads a page.
enum WhatsNewActions {
    static func perform(_ action: WhatsNewAction, in c: WindowController?) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        switch action {
        case .commandBar:
            guard let c else { return }
            if c.commandBar == nil { c.openCommandBar(mode: .newTab) }
            c.showToast("Type a site, a search, an open tab or a command. ⌘T opens this anytime.")
        case .settingsAppIcon: app.showSettings(page: .appearance, section: "App Icon")
        case .settingsSitePreviews: app.showSettings(page: .appearance, section: "Site Previews")
        case .settingsAgents: app.showSettings(page: .agents)
        case .settingsSync: app.showSettings(page: .sync)
        case .settingsImport: app.showSettings(page: .importing)
        case .settingsBoosts: app.showSettings(page: .boosts)
        case .settingsGeneral: app.showSettings(page: .general)
        case .settingsUpdates: app.showSettings(page: .general, section: "Automatic Updates")
        case .settingsAI: app.showSettings(page: .ai, section: "Downloads")
        case .settingsShortcuts: app.showSettings(page: .shortcuts)
        case .libraryArchive: c?.showLibrary(.archive)
        case .libraryNotes: c?.showLibrary(.notes)
        case .sendFeedback:
            guard let c else { return }
            FeedbackSheet.show(from: c.window, app: app)
        }
    }
}

extension AppDelegate {
    /// Settings on `page`, scrolled to the section titled `section` (whatsnew2's "Show me").
    func showSettings(page: SettingsPage, section: String) {
        showSettings(page: page)
        settingsWindow?.model.reveal(section)
    }
}

// MARK: - The view

/// The page in the card: the SwiftUI page, clipped to the card's corners (as a note's editor).
final class WhatsNewPageView: NSView {
    let model: WhatsNewPageModel
    private let hosting: NSHostingView<AnyView>

    init(model: WhatsNewPageModel) {
        self.model = model
        hosting = NSHostingView(rootView: AnyView(WhatsNewPageRoot(model: model).testAnchorRoot()))
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.cornerRadius = AircMetrics.Window.cardRadius
        layer?.cornerCurve = .circular
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        setAccessibilityIdentifier("whats-new-page")
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set { if layer?.cornerRadius != newValue { layer?.cornerRadius = newValue } }
    }

    func applyTheme() {
        let t = model.theme
        layer?.backgroundColor = t.surface.nsColor.cgColor
        layer?.borderColor = t.isDark ? NSColor.white.withAlphaComponent(0.06).cgColor : NSColor.black.withAlphaComponent(0.08).cgColor
        appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
    }
}

struct WhatsNewPageRoot: View {
    @ObservedObject var model: WhatsNewPageModel

    var body: some View {
        let theme = model.theme
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(theme)
                    if let content = model.content {
                        ForEach(content.sections, id: \.version) { section in
                            sectionView(section, newest: section.version == content.version, theme)
                        }
                    } else {
                        Text("This version has no list of new things. The changelog has every change.")
                            .aircFont(AircFont.lead).foregroundStyle(theme.surfaceTextSecondary.color)
                            .padding(.top, 28)
                    }
                    footer(theme).id(WhatsNewPageModel.footerID)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 56)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
            }
        }
        .background(theme.surface.color)
        .aircTheme(theme)
        .environment(\.colorScheme, theme.colorScheme)
    }

    private func header(_ theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
                .accessibilityHidden(true)
            Text("What’s new in Airc")
                .aircFont(AircFont.display).foregroundStyle(theme.surfaceText.color)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .aircFont(AircFont.lead).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }

    private var subtitle: String {
        guard let c = model.content else { return "You’re up to date." }
        let first = "You’re now on Airc \(c.version)."
        guard let from = c.from else { return first + " Here’s what it brings, and where to find it." }
        return first + " Here’s what changed since \(from), and where to find each thing."
    }

    private func sectionView(_ s: WhatsNewPageContent.Section, newest: Bool, _ theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(newest ? "New in \(s.version)" : "Also new, from \(s.version)")
                .aircFont(AircFont.caption).textCase(.uppercase)
                .foregroundStyle(theme.surfaceTextTertiary.color)
                .accessibilityAddTraits(.isHeader)
            ForEach(s.highlights, id: \.title) { h in
                item(h, theme).id(WhatsNewPageModel.id(s.version, h))
                    .testAnchor("whatsnew.item.\(WhatsNewPageModel.id(s.version, h))")
            }
        }
        .padding(.top, 32)
    }

    private func item(_ h: WhatsNewHighlight, _ theme: ResolvedTheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: AircRadius.popover, style: .continuous)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: h.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: AircRadius.control, style: .continuous)
                        .fill(theme.accent.alpha(theme.isDark ? 0.22 : 0.12).color))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(h.title)
                        .aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                        .accessibilityAddTraits(.isHeader)
                    Text(h.detail ?? h.spoken)
                        .aircFont(AircFont.lead).foregroundStyle(theme.surfaceTextSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let a = h.action {
                        HStack(spacing: 10) {
                            Button(a.buttonTitle) { model.perform(a) }
                                .buttonStyle(.airc(a == .commandBar || a == .sendFeedback ? .primary : .secondary, size: .small))
                                .accessibilityLabel("\(a.buttonTitle): \(h.title)")
                                .accessibilityHint(a.place)
                                .testAnchor("whatsnew.action.\(a.rawValue)")
                            Text(a.place)
                                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                                .lineLimit(2)
                        }
                        .padding(.top, 6)
                    }
                }
                Spacer(minLength: 0)
            }
            if let img = model.image(h.image) {
                let pic = RoundedRectangle(cornerRadius: AircRadius.tile, style: .continuous)
                let ratio = img.size.height > 0 ? img.size.width / img.size.height : 1.5
                Image(nsImage: img)
                    .resizable().interpolation(.high).aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: 300 * ratio, maxHeight: 300)   // hugs the picture, so its edge is the picture's
                    .clipShape(pic)
                    .overlay(pic.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 48)
                    .accessibilityLabel("Picture: \(h.title)")
                    .testAnchor("whatsnew.image.\(h.image ?? "")")
            }
        }
        .padding(18)
        .background(shape.fill((theme.isDark ? AircColor.white(0.045).over(theme.surface) : AircColor.white()).color))
        .overlay(shape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }

    private func footer(_ theme: ResolvedTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Read the full changelog") { model.openChangelog() }
                .buttonStyle(.airc(.plain, size: .small))
                .foregroundStyle(theme.accentText.color)
                .testAnchor("whatsnew.changelog")
            HStack(spacing: 4) {
                Text("Choose what Airc shows after an update in")
                    .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color)
                Button("Settings › General") { model.openSettings() }
                    .buttonStyle(.plain)
                    .aircFont(AircFont.callout).foregroundStyle(theme.accentText.color)
                    .testAnchor("whatsnew.settings")
            }
        }
        .padding(.top, 36)
    }
}
