// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import ObjectiveC
import SwiftUI

// The Boost editor (BST-1, Arc's Boost panel): a floating card over the top-right corner of the page, opened from Site
// Controls ("Boost this site") or View → Boost This Site…. Four sections, all live on the page while you edit:
// Colors (tint, brightness, contrast, saturation, invert), Font (a system font, the page's size as its zoom, and a
// letter case), Zap (click elements to hide them) and
// Code (the site's own CSS and JavaScript, saved with Save or ⌘S; the JavaScript runs on the host it was saved on unless
// "All of <site>" is on). A Boost held since the move to the whole public suffix list (`Boost.needsSite`) shows as a
// banner on the pages it may have been made for, to use there or delete. It stays open while you work on the page; ✕ or Esc
// close it (Esc first ends Zap), and so does leaving the site or the tab. The card follows the Site Controls card's
// surface (radius 14, popover shadow), 320 pt wide. The header's name opens Arc's Boost menu: Rename, Reset All Edits,
// Share and Delete (BST-3).

// MARK: - Model

final class BoostEditorModel: ObservableObject {
    enum Section: String, CaseIterable { case colors, font, zap, code }
    enum CodeKind: String { case css, js }

    let domain: String
    /// The page's own host ("www.nytimes.com"): where new JavaScript runs.
    let pageHost: String?
    /// The site is one exact host (an address, "github.io"): its code can't be for a part of it.
    let isExactSite: Bool
    private(set) weak var page: EngineTab?
    weak var controller: WindowController?
    let ui: ResolvedTheme

    @Published private(set) var boost: Boost
    /// The Boost is stored (anything was ever set, or it was switched).
    @Published private(set) var exists: Bool
    @Published var section: Section = .colors
    @Published var codeKind: CodeKind = .css
    @Published var css: String { didSet { keepDraft() } }
    @Published var js: String { didSet { keepDraft() } }
    @Published private(set) var zapping = false
    @Published var notice: String?
    /// The JavaScript runs on every page of the site (the Boost's `scriptHost` is nil). For code not saved yet, the
    /// choice its first Save takes: off, the page's host.
    @Published private(set) var scriptAllOfSite = false
    /// A held Boost this page may be what it was made for.
    @Published private(set) var held: Boost?
    /// Something was changed in this session (`boost_saved`, once, when it closes).
    private(set) var edited = false

    /// Unsaved code by site, until it's saved or reverted (closing the card keeps it for this run of the app).
    private static var drafts: [String: (css: String, js: String)] = [:]

    private var center: BoostCenter? { BoostCenter.shared }
    var codeDirty: Bool { css != boost.css || js != boost.js }

    init(domain: String, page: EngineTab?, ui: ResolvedTheme) {
        self.domain = domain
        self.page = page
        self.ui = ui
        pageHost = BoostDomain.webHost(of: page?.url)
        isExactSite = BoostDomain.isExactHost(domain)
        let stored = BoostCenter.shared?.store.boost(domain: domain)
        boost = stored ?? Boost(domain: domain)
        exists = stored != nil
        let draft = Self.drafts[domain]
        css = draft?.css ?? stored?.css ?? ""
        js = draft?.js ?? stored?.js ?? ""
        zapping = BoostCenter.shared?.isZapping(page) == true
        scriptAllOfSite = stored.map { $0.hasScript && $0.scriptHost == nil } ?? false
        held = pageHost.flatMap { BoostCenter.shared?.store.heldBoost(coveringHost: $0) }
    }

    func reload() {
        let stored = center?.store.boost(domain: domain)
        let next = stored ?? Boost(domain: domain)
        let cleanCode = !codeDirty
        if next != boost { boost = next }
        if cleanCode { css = next.css; js = next.js }
        if exists != (stored != nil) { exists = stored != nil }
        let z = center?.isZapping(page) == true
        if z != zapping { zapping = z }
        if next.hasScript, scriptAllOfSite != (next.scriptHost == nil) { scriptAllOfSite = next.scriptHost == nil }
        let h = pageHost.flatMap { center?.store.heldBoost(coveringHost: $0) }
        if h != held { held = h }
    }

    private func change(_ f: (inout Boost) -> Void) {
        edited = true
        center?.update(domain: domain, f)
        reload()
    }

    private func keepDraft() {
        if css == boost.css && js == boost.js { Self.drafts[domain] = nil } else { Self.drafts[domain] = (css, js) }
    }

    // MARK: Bindings

    var enabled: Binding<Bool> {
        Binding(get: { self.boost.enabled }, set: { on in
            self.edited = true
            self.center?.setEnabled(on, domain: self.domain, page: self.page)
            self.reload()
        })
    }

    func color<T>(_ key: WritableKeyPath<BoostColors, T>) -> Binding<T> {
        Binding(get: { self.boost.colors[keyPath: key] }, set: { v in self.change { $0.colors[keyPath: key] = v } })
    }

    func resetColors() { change { $0.colors = BoostColors(hue: $0.colors.hue) } }

    func setFamily(_ family: BoostFontFamily?) { change { $0.font.family = family?.rawValue } }

    func setCase(_ textCase: BoostTextCase?) { change { $0.font.textCase = textCase?.rawValue } }

    /// The header's title: the Boost's name, or "Boost".
    var title: String { boost.name ?? "Boost" }

    /// Where it came from, for the footer: "From Sam · version 2", "Shared · version 3", "From the Airc gallery".
    var originLine: String? {
        guard let o = boost.origin else { return nil }
        let edited = o.edited(boost) ? " · edited" : ""
        switch o.kind {
        case .shared: return "Shared · version \(o.revision)\(edited)"
        case .installed:
            if o.gallery { return "From the gallery\(edited)" }
            return "From \(o.author ?? "someone") · version \(o.revision)\(edited)"
        }
    }

    func rename(_ name: String) {
        edited = true
        center?.store.rename(domain: domain, to: name)
        reload()
    }

    /// Arc's "Reset all Edits": every setting, zap and line of code back to none (the name and switch stay).
    func resetAllEdits() {
        change {
            $0.colors = BoostColors(); $0.font = BoostFont(); $0.zaps = []; $0.css = ""; $0.js = ""; $0.scriptHost = nil
        }
        css = ""; js = ""
        Self.drafts[domain] = nil
    }

    /// The CSS's leading imports and how each loads (BoostCSSImports), with what the pages reported.
    var importLines: [(url: String, ok: Bool, note: String)] {
        let failures = center?.importFailures[domain] ?? [:]
        return BoostCSSImports.review(css, site: domain).map { rule, source in
            if let why = failures[rule.url] { return (rule.url, false, BoostCSSImports.runtimeExplanation(why)) }
            switch source {
            case .inline: return (rule.url, true, "Loaded from the CSS itself.")
            case .samePage: return (rule.url, true, "Loaded from each page's own site.")
            case .host(let h): return (rule.url, true, "Loaded on \(h)'s pages.")
            case .refused(let r): return (rule.url, false, r.explanation)
            }
        }
    }

    func stepSize(_ delta: Int) {
        change {
            let r = BoostFont.sizeSteps
            $0.font.size = delta == 0 ? 0 : min(max($0.font.size + delta, r.lowerBound), r.upperBound)
        }
    }

    var sizeText: String { "\(Int((boost.font.scale * 100).rounded())) %" }

    /// The page's zoom isn't the Boost's size: the person zoomed it themselves (BoostZoom leaves theirs).
    var zoomedByPerson: Bool {
        guard let page, boost.isLive else { return false }
        return !BoostZoom.near(page.zoomFactor, boost.font.scale) && boost.font.step != 0
    }

    // MARK: Zap

    func toggleZap() { setZapping(!zapping) }

    func setZapping(_ on: Bool) {
        guard let page, let center else { return }
        center.setZapping(on, tab: page, domain: domain)
        if on { controller?.window.makeFirstResponder(page.view) }
        reload()
    }

    func undoZap(_ id: String) { change { $0.zaps.removeAll { $0.id == id } } }
    func resetZaps() { change { $0.zaps = [] } }

    // MARK: Code

    func saveCode() {
        guard codeDirty else { return }
        edited = true
        center?.saveCode(domain: domain, css: css, js: js, scriptHost: scriptAllOfSite ? nil : boost.scriptHost ?? pageHost, page: page)
        reload()
        Self.drafts[domain] = nil
    }

    /// The host the JavaScript runs on now (nil: every page of the site, or nothing saved yet).
    var scriptHost: String? { boost.hasScript ? boost.scriptHost : nil }

    /// "All of <site>": at once for saved code; for code not saved yet, at its first Save.
    var allOfSite: Binding<Bool> {
        Binding(get: { self.scriptAllOfSite }, set: { on in
            self.scriptAllOfSite = on
            guard self.boost.hasScript else { return }
            self.edited = true
            self.center?.setScriptHost(on ? nil : self.boost.scriptHost ?? self.pageHost, domain: self.domain, page: self.page)
            self.reload()
        })
    }

    /// Saved for another host of the site: it runs on this page's host from now on.
    func runScriptHere() {
        guard let pageHost else { return }
        edited = true
        center?.setScriptHost(pageHost, domain: domain, page: page)
        reload()
    }

    /// Where the code runs, for the line under it.
    var scriptPlace: String {
        if isExactSite { return "Runs on \(domain) only" }
        if scriptAllOfSite { return "Runs on every page of \(domain)" }
        return "Runs on \(scriptHost ?? pageHost ?? domain) only"
    }

    // MARK: A held Boost

    /// The held Boost can come to this site: it has no Boost of its own yet (or this is the held one).
    var canUseHeld: Bool {
        guard let held else { return false }
        return held.domain == domain || (center?.store.boost(domain: domain)?.isEmpty ?? true)
    }

    func useHeld() {
        guard let held, canUseHeld else { return }
        edited = true
        if center?.adoptHeld(held.domain, to: domain, page: page) == true {
            let stored = center?.store.boost(domain: domain)
            css = stored?.css ?? ""
            js = stored?.js ?? ""
            Self.drafts[domain] = nil
        }
        reload()
    }

    func deleteHeld() {
        guard let held else { return }
        center?.remove(domain: held.domain, page: nil)
        reload()
    }

    func revertCode() {
        css = boost.css
        js = boost.js
    }

    func delete() {
        edited = false
        Self.drafts[domain] = nil
        center?.remove(domain: domain, page: page)
        controller?.closeBoostEditor()
    }

    /// The card closes: Zap ends, a Boost that sets nothing is dropped, and a session that changed something counts once.
    func closing() {
        if zapping, let page { center?.setZapping(false, tab: page, domain: domain) }
        if let b = center?.store.boost(domain: domain), b.isEmpty, b.enabled, Self.drafts[domain] == nil {
            center?.remove(domain: domain, page: nil)
        }
        if edited { Telemetry.shared.record(.featureUsed(.boostSaved)) }
        edited = false
    }
}

// MARK: - The card

struct BoostEditorCard: View {
    @ObservedObject var model: BoostEditorModel
    var sizeChanged: (CGSize) -> Void = { _ in }
    var close: () -> Void = {}
    private var ui: ResolvedTheme { model.ui }
    static let width: CGFloat = 320
    private let inset: CGFloat = AircSpacing.m + 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let held = model.held { heldBanner(held) }
            AircSegmented(selection: $model.section, segments: [
                .init(value: .colors, title: "Colors", symbol: "paintpalette"),
                .init(value: .font, title: "Font", symbol: "textformat"),
                .init(value: .zap, title: "Zap", symbol: "scissors"),
                .init(value: .code, title: "Code", symbol: "chevron.left.forwardslash.chevron.right"),
            ], height: 28)
            .padding(.horizontal, inset)
            .padding(.top, AircSpacing.m)
            .testAnchor("boost.sections")
            Group {
                switch model.section {
                case .colors: colors
                case .font: font
                case .zap: zap
                case .code: code
                }
            }
            .padding(.top, AircSpacing.m)
            .opacity(model.boost.enabled ? 1 : 0.45)
            if let notice = model.notice {
                Text(notice).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                    .padding(.horizontal, inset).padding(.top, AircSpacing.s)
                    .testAnchor("boost.notice")
            }
            divider
            footer
        }
        .padding(.vertical, AircSpacing.m)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.onAppear { sizeChanged(g.size) }.onChange(of: g.size) { _, size in sizeChanged(size) }
        })
        .testAnchorRoot()
        .aircTheme(ui)
    }

    private var divider: some View {
        Rectangle().fill(ui.surfaceBorder.color).frame(height: 0.5).padding(.vertical, AircSpacing.s + 2)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "paintbrush.pointed.fill").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ui.onAccent.color)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.accent.color))
            VStack(alignment: .leading, spacing: 1) {
                if model.exists {
                    Menu {
                        Button("Rename This Boost…") { model.controller?.renameBoost(model) }
                        Button("Reset All Edits") { model.resetAllEdits() }.disabled(model.boost.isEmpty)
                        Divider()
                        Button("Share Boost…") { model.controller?.shareBoost(model) }
                        Button("Delete This Boost") { model.delete() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.title).aircFont(AircFont.title3).foregroundStyle(ui.surfaceText.color).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(ui.surfaceTextTertiary.color)
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Rename, reset, share or delete this Boost")
                    .testAnchor("boost.menu")
                } else {
                    Text(model.title).aircFont(AircFont.title3).foregroundStyle(ui.surfaceText.color)
                }
                Text(model.domain).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                    .lineLimit(1).truncationMode(.middle)
                    .testAnchor("boost.domain")
            }
            Spacer(minLength: AircSpacing.s)
            if model.exists {
                AircSwitch(isOn: model.enabled)
                    .help(model.boost.enabled ? "Turn this Boost off" : "Turn this Boost on")
                    .testAnchor("boost.switch")
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(ui.surfaceTextSecondary.color)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(BoostPlateStyle(ui: ui, radius: 7))
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            .testAnchor("boost.close")
        }
        .padding(.horizontal, inset)
    }

    // MARK: A held Boost

    /// "A Boost for all of duckdns.org is paused": made before Airc knew the site is shared hosting.
    private func heldBanner(_ held: Boost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "pause.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(ui.accent.color)
                Text("A Boost for all of \(held.domain) is paused").aircFont(AircFont.body.weight(.semibold))
                    .foregroundStyle(ui.surfaceText.color).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.canUseHeld
                 ? "Sites on \(held.domain) belong to different people, so it applies nowhere and its code doesn't run until you choose a site for it."
                 : "Sites on \(held.domain) belong to different people, so it applies nowhere. This site has a Boost of its own.")
                .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Delete It") { model.deleteHeld() }.buttonStyle(.airc(.plain, size: .small)).testAnchor("boost.held.delete")
                if model.canUseHeld {
                    Button("Use for \(model.domain)") { model.useHeld() }.buttonStyle(.airc(.primary, size: .small))
                        .lineLimit(1).testAnchor("boost.held.use")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.fieldFill.color))
        .padding(.horizontal, inset)
        .padding(.top, AircSpacing.m)
        .testAnchor("boost.held")
    }

    // MARK: Colors

    private var colors: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Tint", value: model.boost.colors.tint > 0.005 ? "\(Int((model.boost.colors.tint * 100).rounded())) %" : "Off") {
                BoostHueTrack(hue: model.color(\.hue), tint: model.boost.colors.tint) {
                    if model.boost.colors.tint < 0.005 { model.color(\.tint).wrappedValue = 0.45 }
                }
                .testAnchor("boost.hue")
                AircSlider(value: model.color(\.tint), range: 0...1).testAnchor("boost.tint")
            }
            labeled("Brightness", value: percent(model.boost.colors.brightness)) {
                AircSlider(value: model.color(\.brightness), range: BoostColors.range).testAnchor("boost.brightness")
            }
            labeled("Contrast", value: percent(model.boost.colors.contrast)) {
                AircSlider(value: model.color(\.contrast), range: BoostColors.range).testAnchor("boost.contrast")
            }
            labeled("Original Saturation", value: percent(model.boost.colors.saturation)) {
                AircSlider(value: model.color(\.saturation), range: BoostColors.saturationRange).testAnchor("boost.saturation")
            }
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Invert").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                    Text("A quick dark mode").aircFont(AircFont.callout)
                        .foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1)
                }
                Spacer(minLength: 4)
                AircSwitch(isOn: model.color(\.invert)).testAnchor("boost.invert")
            }
            .padding(.top, 2)
            HStack {
                Spacer()
                Button("Reset Colors") { model.resetColors() }
                    .buttonStyle(.airc(.plain, size: .small))
                    .disabled(model.boost.colors.isDefault)
                    .testAnchor("boost.resetColors")
            }
        }
        .padding(.horizontal, inset)
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }

    private func labeled<Content: View>(_ title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                Spacer()
                Text(value).aircFont(AircFont.callout.weight(.medium)).monospacedDigit().foregroundStyle(ui.surfaceTextTertiary.color)
            }
            content()
        }
    }

    // MARK: Font

    private var font: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                fontChoice(nil)
                ForEach(BoostFontFamily.allCases, id: \.self) { fontChoice($0) }
            }
            HStack(spacing: 8) {
                Image(systemName: "textformat.size").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Size").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                    Text(model.zoomedByPerson ? "You zoomed this page yourself" : "The whole page, like ⌘+")
                        .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color)
                        .testAnchor("boost.sizeNote")
                }
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    stepButton("minus", help: "Smaller", anchor: "boost.sizeDown") { model.stepSize(-1) }
                        .disabled(model.boost.font.size <= BoostFont.sizeSteps.lowerBound)
                    Text(model.sizeText).aircFont(AircFont.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(ui.surfaceText.color).frame(width: 46)
                        .testAnchor("boost.sizeValue")
                    stepButton("plus", help: "Larger", anchor: "boost.sizeUp") { model.stepSize(1) }
                        .disabled(model.boost.font.size >= BoostFont.sizeSteps.upperBound)
                }
                .background(Capsule(style: .continuous).fill(ui.fieldFill.color))
            }
            HStack(spacing: 8) {
                Image(systemName: "textformat").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 18)
                Text("Case").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    caseChoice(nil)
                    ForEach(BoostTextCase.allCases, id: \.self) { caseChoice($0) }
                }
                .padding(2)
                .background(Capsule(style: .continuous).fill(ui.fieldFill.color))
            }
        }
        .padding(.horizontal, inset)
    }

    /// Arc's case button, as a strip: the site's own, Title Case, CAPITALS, lowercase.
    private func caseChoice(_ c: BoostTextCase?) -> some View {
        let on = model.boost.font.knownCase == c
        return Button { model.setCase(c) } label: {
            Text(c?.sample ?? "—").aircFont(AircFont.callout.weight(on ? .semibold : .regular))
                .foregroundStyle((on ? ui.onAccent : ui.surfaceText).color)
                .frame(width: 34, height: 22)
                .background(Capsule(style: .continuous).fill(on ? ui.accent.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c?.title ?? "The site's own case")
        .accessibilityLabel(c?.title ?? "The site's own case")
        .testAnchor("boost.case.\(c?.rawValue ?? "site")")
    }

    private func fontChoice(_ family: BoostFontFamily?) -> some View {
        let on = model.boost.font.knownFamily == family
        return Button { model.setFamily(family) } label: {
            HStack(spacing: 8) {
                Text("Aa").font(Self.sample(family))
                    .foregroundStyle(ui.surfaceText.color)
                    .frame(width: 24)
                Text(family?.title ?? "Site's Font").aircFont(AircFont.callout.weight(on ? .semibold : .regular))
                    .foregroundStyle(ui.surfaceText.color).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((on ? ui.accent.alpha(ui.isDark ? 0.22 : 0.10) : ui.surfaceText.alpha(0.04)).color))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).inset(by: 0.5)
                .stroke((on ? ui.accent : ui.surfaceText.alpha(0.08)).color, lineWidth: on ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .testAnchor("boost.font.\(family?.rawValue ?? "site")")
    }

    /// Each choice drawn in its own face (the family's regular weight, from macOS's font manager).
    static func sample(_ f: BoostFontFamily?) -> Font {
        let family: String? = switch f {
        case nil, .system: nil
        case .helvetica: "Helvetica Neue"
        case .avenir: "Avenir Next"
        case .georgia: "Georgia"
        case .charter: "Charter"
        case .menlo: "Menlo"
        }
        guard let family, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 15) else {
            return .system(size: 15, weight: .regular)
        }
        return Font(font as CTFont)
    }

    private func stepButton(_ symbol: String, help: String, anchor: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(ui.surfaceTextSecondary.color)
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(BoostPlateStyle(ui: ui, radius: 12))
        .help(help)
        .accessibilityLabel(help)
        .testAnchor(anchor)
    }

    // MARK: Zap

    private var zap: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.toggleZap() } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.zapping ? "scissors.circle.fill" : "scissors").font(.system(size: 13, weight: .semibold))
                    Text(model.zapping ? "Done Zapping" : "Zap Elements").aircFont(AircFont.body.weight(.semibold))
                    Spacer(minLength: 0)
                    if model.zapping { Text("Esc").aircFont(AircFont.micro).opacity(0.8) }
                }
                .foregroundStyle((model.zapping ? ui.onAccent : ui.surfaceText).color)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((model.zapping ? ui.accent : ui.surfaceText.alpha(0.06)).color))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.boost.enabled && model.exists)
            .testAnchor("boost.zap")
            Text(model.zapping ? "Point at something on the page and click it to hide it. Hold ⌥ to hide everything like it."
                               : "Hide parts of the page you never want to see. They stay hidden on every visit.")
                .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
            if !model.boost.zaps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.boost.zaps.reversed()) { z in zapRow(z) }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.fieldFill.color))
                .testAnchor("boost.zaps")
                HStack {
                    Text(model.boost.zaps.count == 1 ? "1 element hidden" : "\(model.boost.zaps.count) elements hidden")
                        .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                    Spacer()
                    Button("Reset Zaps") { model.resetZaps() }.buttonStyle(.airc(.plain, size: .small)).testAnchor("boost.resetZaps")
                }
            }
        }
        .padding(.horizontal, inset)
    }

    private func zapRow(_ z: BoostZap) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(z.label.isEmpty ? "Element" : z.label).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color).lineLimit(1)
                // A zap made inside a frame of the page says so: it hides that element in the site's frames only.
                Text((z.frame ? "In a frame · " : "") + z.selector).aircFont(AircFont.mono).foregroundStyle(ui.surfaceTextTertiary.color)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button { model.undoZap(z.id) } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(BoostPlateStyle(ui: ui, radius: 7))
            .help("Show it again")
            .accessibilityLabel("Show \(z.label.isEmpty ? "element" : z.label) again")
            .testAnchor("boost.undoZap.\(z.frame ? "frame." : "")\(z.selector)")
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }

    // MARK: Code

    private var code: some View {
        VStack(alignment: .leading, spacing: 8) {
            AircSegmented(selection: $model.codeKind, segments: [
                .init(value: .css, title: "CSS"), .init(value: .js, title: "JavaScript"),
            ], height: 26)
            ZStack(alignment: .topLeading) {
                if model.codeKind == .css {
                    BoostCodeEditor(text: $model.css, ui: ui, save: { model.saveCode() }).id("css")
                } else {
                    BoostCodeEditor(text: $model.js, ui: ui, save: { model.saveCode() }).id("js")
                }
                if (model.codeKind == .css ? model.css : model.js).isEmpty {
                    Text(model.codeKind == .css ? "body { line-height: 1.6; }" : "document.title = '★ ' + document.title;")
                        .aircFont(AircFont.mono).foregroundStyle(ui.surfaceTextTertiary.color)
                        .padding(.horizontal, 11).padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.fieldFill.color))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: 0.25).stroke(ui.surfaceBorder.color, lineWidth: 0.5))
            .testAnchor("boost.code")
            if model.codeKind == .css, !model.importLines.isEmpty { imports }
            if model.codeKind == .js, !model.isExactSite { scriptScope }
            Text(model.codeKind == .css ? "Added after the site's own styles, on every page of \(model.domain)."
                                        : "\(model.scriptPlace), once each time a page loads. Only code you save or explicitly install runs.")
                .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
                .testAnchor("boost.scriptPlace")
            HStack(spacing: 8) {
                if model.codeDirty {
                    Text("Unsaved").aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                }
                Spacer()
                Button("Revert") { model.revertCode() }.buttonStyle(.airc(.plain, size: .small))
                    .disabled(!model.codeDirty).testAnchor("boost.revert")
                Button("Save") { model.saveCode() }.buttonStyle(.airc(.primary, size: .small))
                    .disabled(!model.codeDirty).help("Save (⌘S)").testAnchor("boost.save")
            }
        }
        .padding(.horizontal, inset)
    }

    /// The CSS's `@import`s: which load (from the CSS itself or the site) and which are skipped, and why.
    private var imports: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.importLines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: line.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(line.ok ? ui.surfaceTextTertiary.color : Color.orange)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(line.url).aircFont(AircFont.mono).foregroundStyle(ui.surfaceText.color).lineLimit(1).truncationMode(.middle)
                        Text(line.note).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .testAnchor("boost.imports")
    }

    /// "All of nytimes.com": the JavaScript on every page of the site, not just the host it was saved on; and, for
    /// code saved on another host, "Run Here Instead".
    private var scriptScope: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe").font(.system(size: 12, weight: .medium))
                .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 18)
            Text("All of \(model.domain)").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if !model.scriptAllOfSite, let saved = model.scriptHost, saved != model.pageHost, model.pageHost != nil {
                Button("Run Here Instead") { model.runScriptHere() }.buttonStyle(.airc(.plain, size: .small))
                    .help("Run it on \(model.pageHost ?? "") instead of \(saved)").testAnchor("boost.runHere")
            }
            AircSwitch(isOn: model.allOfSite).help("Run this code on every page of \(model.domain)").testAnchor("boost.allOfSite")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: model.originLine == nil ? "lock" : "person.2").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ui.surfaceTextTertiary.color)
            Text(model.originLine ?? "On this Mac").aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color)
                .lineLimit(1).truncationMode(.tail)
                .testAnchor("boost.origin")
            Spacer(minLength: 4)
            if model.exists {
                Button("Share…") { model.controller?.shareBoost(model) }
                    .buttonStyle(.airc(.plain, size: .small)).testAnchor("boost.share")
                Button("Delete") { model.delete() }.buttonStyle(.airc(.plain, size: .small))
                    .help("Delete this Boost").testAnchor("boost.delete")
            }
        }
        .padding(.horizontal, inset)
    }
}

/// Arc's hue strip for the tint: the spectrum, with the knob in the chosen hue. Touching it turns the tint on.
struct BoostHueTrack: View {
    @Binding var hue: Double
    var tint: Double
    var began: () -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width - 20)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 0.62, brightness: 0.96) },
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                    .padding(.horizontal, 10)
                    .opacity(tint > 0.005 ? 1 : 0.55)
                AircKnob()
                    .overlay(Circle().fill(Color(hue: hue, saturation: 0.62, brightness: 0.96)).padding(5))
                    .offset(x: w * min(max(hue, 0), 1))
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if !dragging { dragging = true; began() }
                hue = min(max(0, (v.location.x - 10) / w), 1)
            }.onEnded { _ in dragging = false })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Tint color")
        .accessibilityValue("\(Int((hue * 360).rounded())) degrees")
        .accessibilityAdjustableAction { dir in hue = min(1, max(0, hue + (dir == .increment ? 1.0 / 24 : -1.0 / 24))) }
    }
}

/// The card's small buttons: `surfaceHover` on hover, a little darker pressed (the Site Controls card's plates).
struct BoostPlateStyle: ButtonStyle {
    let ui: ResolvedTheme
    let radius: CGFloat
    func makeBody(configuration: Configuration) -> some View { BoostPlate(configuration: configuration, ui: ui, radius: radius) }
}

private struct BoostPlate: View {
    let configuration: ButtonStyleConfiguration
    let ui: ResolvedTheme
    let radius: CGFloat
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .opacity(enabled ? 1 : 0.4)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(!enabled ? .clear : configuration.isPressed ? ui.surfaceText.alpha(0.09).color : hovered ? ui.surfaceHover.color : .clear))
            .onHover { hovered = $0 }
    }
}

// MARK: - The code editor

/// The code views' text view: plain text, monospaced, no smart quotes or corrections. ⌘S saves (Commands.swift).
final class BoostCodeTextView: NSTextView {
    var save: (() -> Void)?
}

struct BoostCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let ui: ResolvedTheme
    var save: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // Zero wide: the clip view's first resize sets the width (autoresizing adds to the start width).
        let tv = BoostCodeTextView(frame: NSRect(x: 0, y: 0, width: 0, height: 170))
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.textColor = ui.surfaceText.nsColor
        tv.insertionPointColor = ui.accent.nsColor
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.string = text
        tv.delegate = context.coordinator
        tv.save = save
        tv.setAccessibilityLabel("Code")
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? BoostCodeTextView else { return }
        tv.save = save
        if tv.string != text { tv.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BoostCodeEditor
        init(_ parent: BoostCodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

// MARK: - The view

/// The card's NSView over the page: `surface`, radius 14, the popover shadow. First click works in a window that
/// isn't key; it never moves the window.
final class BoostEditorPanelView: NSView {
    let model: BoostEditorModel
    private var host: AircFirstClickHostingView<BoostEditorCard>!
    private var contentSize: CGSize = .zero
    private(set) var isClosing = false

    init(model: BoostEditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.popover
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = model.ui.surface.nsColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = model.ui.surfaceBorder.nsColor.cgColor
        layer?.applyAircShadow(.popover)
        var card = BoostEditorCard(model: model)
        card.close = { [weak self] in self?.model.controller?.closeBoostEditor() }
        card.sizeChanged = { [weak self] size in
            guard size.height > 1 else { return }
            DispatchQueue.main.async {
                guard let self, !self.isClosing, self.contentSize != size else { return }
                self.contentSize = size
                if self.model.controller?.boostEditor === self { self.model.controller?.placeBoostEditor() }
            }
        }
        host = AircFirstClickHostingView(rootView: card)
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.layer?.cornerRadius = AircRadius.popover
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var hostingView: NSView { host }

    func place(at origin: NSPoint, maxHeight: CGFloat) {
        let size = contentSize.height > 1 ? contentSize : host.fittingSize
        frame = NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: size.width, height: min(size.height, max(160, maxHeight)))
        host.frame = bounds
    }

    func present() {
        guard let layer else { return }
        if onMain({ AircMotion.prefersReducedMotion }) { layer.fade(from: 0, to: 1, duration: 0.15); return }
        layer.add(AircSpring.grow.caAnimation(keyPath: "transform.scale", from: 0.96, to: 1), forKey: "grow")
        layer.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
    }

    func dismiss(animated: Bool) {
        guard !isClosing else { return }
        isClosing = true
        guard animated, let layer else { return removeFromSuperview() }
        layer.fade(from: 1, to: 0, duration: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.removeFromSuperview() }
    }
}

// MARK: - The window's Boost editor

extension WindowController {
    private static var boostPanelKey = 0
    private static var boostObserversKey = 0

    /// The editor while it's open.
    var boostEditor: BoostEditorPanelView? {
        get { objc_getAssociatedObject(self, &Self.boostPanelKey) as? BoostEditorPanelView }
        set { objc_setAssociatedObject(self, &Self.boostPanelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var boostObservers: [NSObjectProtocol] {
        get { objc_getAssociatedObject(self, &Self.boostObserversKey) as? [NSObjectProtocol] ?? [] }
        set { objc_setAssociatedObject(self, &Self.boostObserversKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Engines without a page script have no Boosts.
    var boostsAvailable: Bool { BoostCenter.shared != nil }

    /// View → Boost This Site…, Site Controls' "Boost this site": the editor for the site on screen (the focused pane
    /// in a split). Open already, it comes to that page's site.
    func showBoostEditor(section: BoostEditorModel.Section? = nil) {
        guard boostsAvailable else { return showToast("Boosts need the Chromium engine") }
        guard let id = shownTabID, let page = engineTab(for: id), !page.isClosed else { return NSSound.beep() }
        guard let domain = BoostDomain.key(for: page.url) else { return showToast("Boosts work on websites") }
        showBoostEditor(domain: domain, page: page, section: section)
    }

    func showBoostEditor(domain: String, page: EngineTab? = nil, section: BoostEditorModel.Section? = nil) {
        let shown = shownTabID.flatMap { engineTab(for: $0) }
        let page = page ?? (BoostDomain.key(for: shown?.url) == domain ? shown : nil)
        if let open = boostEditor, open.model.domain == domain, open.model.page === page {
            if let section { open.model.section = section }
            return
        }
        closeBoostEditor(animated: false)
        closeSiteControls(animated: false)
        let model = BoostEditorModel(domain: domain, page: page, ui: currentPalette.resolved)
        if let section { model.section = section }
        model.controller = self
        let panel = BoostEditorPanelView(model: model)
        if toast.superview === root { root.addSubview(panel, positioned: .below, relativeTo: toast) } else { root.addSubview(panel) }
        boostEditor = panel
        placeBoostEditor()
        panel.present()
        observeBoostEditor(panel)
    }

    /// ✕, Esc, Delete, the page going away. True when there was an editor to close.
    @discardableResult
    func closeBoostEditor(animated: Bool = true) -> Bool {
        guard let panel = boostEditor else { return false }
        boostEditor = nil
        boostObservers.forEach(NotificationCenter.default.removeObserver)
        boostObservers = []
        panel.model.closing()
        if window.firstResponder is BoostCodeTextView, let page = panel.model.page { window.makeFirstResponder(page.view) }
        panel.dismiss(animated: animated)
        return true
    }

    /// The top-right corner of the page card (12 pt in), inside the window.
    func placeBoostEditor() {
        guard let panel = boostEditor else { return }
        let page = card.isHidden || card.frame.width < 1 ? root.bounds : card.frame
        let x = max(8, page.maxX - BoostEditorCard.width - 12)
        let y = page.minY + 12
        panel.place(at: NSPoint(x: x, y: y), maxHeight: root.bounds.height - y - 12)
    }

    /// Esc: ends Zap first, then closes the editor.
    func boostEditorHandlesEscape() -> Bool {
        guard let panel = boostEditor else { return false }
        if panel.model.zapping { panel.model.setZapping(false); return true }
        return closeBoostEditor()
    }

    /// ⌘S in the code view.
    func boostEditorSavesCode() -> Bool {
        guard boostEditor != nil, let tv = window.firstResponder as? BoostCodeTextView else { return false }
        tv.save?()
        return true
    }

    /// A URL field redrew: the editor closes once the page on screen isn't its page, or its page left the site.
    func boostEditorPageChanged() {
        guard let panel = boostEditor, !panel.isClosing, panel.model.page != nil else { return }
        let shown = shownTabID.flatMap { engineTab(for: $0) }
        guard let page = panel.model.page, page === shown, !page.isClosed,
              let url = page.url, URLRules.isNewTab(url.absoluteString) || BoostDomain.key(for: url) == panel.model.domain
        else { closeBoostEditor(); return }
    }

    private func observeBoostEditor(_ panel: BoostEditorPanelView) {
        let nc = NotificationCenter.default
        boostObservers = [
            nc.addObserver(forName: BoostCenter.didChange, object: nil, queue: .main) { [weak panel] note in
                guard let model = panel?.model else { return }
                if let d = note.userInfo?["domain"] as? String, d != model.domain { return }
                model.reload()
            },
            nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak panel] _ in
                guard let self, panel != nil, self.boostEditor === panel else { return }
                self.placeBoostEditor()
            },
            nc.addObserver(forName: NSView.frameDidChangeNotification, object: card, queue: .main) { [weak self, weak panel] _ in
                guard let self, panel != nil, self.boostEditor === panel else { return }
                self.placeBoostEditor()
            },
        ]
        BoostCenter.shared?.zapFailed = { [weak panel] in
            panel?.model.notice = "That element can't be zapped on its own. Try the box around it."
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak panel] in panel?.model.notice = nil }
        }
    }
}
