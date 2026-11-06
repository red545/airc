// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import ObjectiveC
import SwiftUI

// Site Controls (SB-2; Arc's "Site Control Center"): the URL field's slider button (shown on hover, 30 × 30 at the
// field's right end, research §2.2) or one of its indicators opens a card under the field, where the permission
// prompts hang (PagePrompts.swift): the site with its favicon and connection (certificate on click), what the page
// uses now (camera, microphone, screen, location), what macOS keeps from Airc that the site wants (SystemPrivacy.swift),
// the pop-ups it blocked, the site's permissions in this Space's profile, its zoom, its cookies and storage, and Copy
// link. It grows from the field on Arc's popover spring (`grow`) and closes with Esc, a click outside, or when
// the page it describes goes off screen. Every change applies at once.
//
// Arc's panel itself isn't measured in the research note; the card follows the prompt card's geometry (surface,
// radius 14, popover shadow, 6 pt under the field) at 300 pt wide.

// MARK: - Model

final class SiteControlsModel: ObservableObject {
    private(set) weak var page: EngineTab?
    let center: SiteControlsCenter?
    let ui: ResolvedTheme
    let profileName: String?
    weak var controller: WindowController?

    @Published private(set) var origin: String?
    @Published private(set) var host = ""
    @Published private(set) var title = ""
    @Published private(set) var favicon: NSImage?
    @Published private(set) var security = SiteSecurity()
    @Published var showsConnection = false
    @Published private(set) var permissions: [SitePermission: SitePermissionValue] = [:]
    @Published var showsMore = false
    @Published private(set) var zoom: Double = 1
    @Published private(set) var zoomScope: SiteZoomScope = .tab
    @Published private(set) var data: SiteDataUsage?
    @Published private(set) var counting = false
    @Published var confirmingClear = false
    @Published private(set) var clearing = false
    @Published private(set) var activity = SiteActivity()
    /// What the site is allowed or asked for and macOS denies Airc (System Settings → Privacy & Security).
    @Published private(set) var systemBlocked: [SystemPrivacy.Kind] = []
    /// The site's Boost (BST-1), if it has one.
    @Published private(set) var boost: Boost?
    /// The menu button the permission menu hangs from.
    var menuAnchor: ((SitePermission) -> NSRect?)?

    /// A WebKit page of the Chromium build has none of Chromium's: Safari's engine asks per request.
    var permissionsAvailable: Bool { center?.engine.sitePermissionsAvailable == true && !usesSafariEngine }
    var dataAvailable: Bool { center?.engine.siteDataAvailable == true }
    var hasCustomPermissions: Bool { permissions.values.contains { $0.isCustom } }
    var listed: [SitePermission] { SitePermission.allCases.filter { permissions[$0] != nil && ($0.isPrimary || showsMore) } }
    var hasMore: Bool { SitePermission.allCases.contains { !$0.isPrimary && permissions[$0] != nil } }
    var isWebsite: Bool { origin != nil }
    /// The site a Boost would be for; nil off the web or on an engine without Boosts.
    var boostDomain: String? { BoostCenter.shared == nil ? nil : BoostDomain.key(for: page?.url) }

    init(page: EngineTab, center: SiteControlsCenter?, ui: ResolvedTheme, profileName: String?) {
        self.page = page
        self.center = center
        self.ui = ui
        self.profileName = profileName
        reload()
        // A device permission set for this site opens "More" by itself.
        showsMore = SitePermission.allCases.contains { !$0.isPrimary && permissions[$0]?.isCustom == true }
        countData()
    }

    /// Everything but the data counts, which are asked for when the card opens and after a clear.
    func reload() {
        guard let page, !page.isClosed else { return }
        let o = SiteOrigin.of(page.url)
        if o != origin { origin = o }
        let h = page.url.map { URLRules.displayHost($0.absoluteString) } ?? ""
        host = h.isEmpty ? (page.title.isEmpty ? "This page" : page.title) : h
        title = page.title
        favicon = page.favicon ?? page.faviconURL.flatMap { FaviconCache.shared.cached($0) }
        security = center?.engine.siteSecurity(of: page) ?? SiteSecurity()
        reloadPermissions()
        reloadActivity()
        reloadSystem()
        reloadZoom()
        reloadBoost()
    }

    func reloadBoost() {
        let b = boostDomain.flatMap { BoostCenter.shared?.store.boost(domain: $0) }
        if b != boost { boost = b }
    }

    func reloadPermissions() {
        guard let page, let origin, let center, !usesSafariEngine else { permissions = [:]; return }
        let p = center.permissions(origin: origin, in: page.profile)
        if p != permissions { permissions = p }
    }

    func reloadActivity() {
        guard let page, let center else { return }
        let a = center.activity(of: page)
        if a != activity { activity = a }
    }

    /// A kind shows when macOS denies it and the site may use it (allowed here), uses it, or asked for it.
    func reloadSystem() {
        guard let page, isWebsite else { if !systemBlocked.isEmpty { systemBlocked = [] }; return }
        let asked = SiteUse.shared.asked(page)
        let k = SystemPrivacy.Kind.allCases.filter { kind in
            let allowed = kind.permission.map { permissions[$0]?.effective == .allow } ?? false
            let using = switch kind {
            case .camera: activity.camera
            case .microphone: activity.microphone
            case .location: activity.location
            case .screen: activity.screen
            }
            return (allowed || using || SiteUse.Ask(rawValue: kind.rawValue).map(asked.contains) == true) && SystemPrivacy.blocks(kind)
        }
        if k != systemBlocked { systemBlocked = k }
    }

    /// The permission's row says macOS keeps it from Airc.
    func systemBlocks(_ p: SitePermission) -> Bool { systemBlocked.contains { $0.permission == p } }

    /// The kinds with no listed permission row to say it (screen recording; every kind on an engine without
    /// permissions) get a row of their own.
    var systemRows: [SystemPrivacy.Kind] {
        systemBlocked.filter { k in k.permission.map { !permissionsAvailable || !listed.contains($0) } ?? true }
    }

    func openSystemSettings(_ kind: SystemPrivacy.Kind) { SystemPrivacy.openSettings(kind) }

    func reloadZoom() {
        guard let page else { return }
        zoom = page.zoomFactor
        zoomScope = center?.engine.zoomScope(of: page) ?? .tab
    }

    func countData() {
        guard let page, let origin, let center, dataAvailable else { data = nil; return }
        counting = true
        center.engine.siteData(origin: origin, in: page.profile) { [weak self] usage in
            self?.data = usage
            self?.counting = false
        }
    }

    // MARK: Actions

    @discardableResult
    func set(_ permission: SitePermission, to state: SitePermissionState) -> Bool {
        guard let page, let origin, let center else { return false }
        let ok = center.set(permission, to: state, origin: origin, in: page.profile)
        reloadPermissions()
        if !ok { controller?.showToast("\(permission.title) can't be changed for this site") }
        return ok
    }

    func resetPermissions() {
        guard let page, let origin, let center else { return }
        center.resetPermissions(origin: origin, in: page.profile)
        reloadPermissions()
    }

    /// −1, +1, or 0 for 100 %: the same steps as ⌘− ⌘+ ⌘0 (Chrome's zoom levels), for the site, or for this tab when its
    /// zoom is its own (a split pane).
    func zoom(step: Int) {
        guard let page else { return }
        page.zoom(step: step)
        reloadZoom()
        center?.pageChanged(page)
    }

    func copyLink() {
        controller?.closeSiteControls()
        controller?.copyURL()
    }

    /// "Boost this site" / Edit: the editor takes over from the card.
    func openBoostEditor() {
        guard let c = controller else { return }
        c.closeSiteControls(animated: false)
        c.showBoostEditor()
    }

    var boostEnabled: Binding<Bool> {
        Binding(get: { self.boost?.enabled ?? false }, set: { [weak self] on in
            guard let self, let d = self.boostDomain else { return }
            BoostCenter.shared?.setEnabled(on, domain: d, page: self.page)
            self.reloadBoost()
        })
    }

    // MARK: Safari's engine (docs/user/protected-media.md)

    /// On a WebKit page (to send a listed site back to Chromium), and on a Chromium page that asked for Widevine.
    var showsSafariEngine: Bool { ProtectedMedia.isWebKitPage(page) || ProtectedMedia.shared.askedForWidevine(page) }
    var usesSafariEngine: Bool { ProtectedMedia.isWebKitPage(page) }
    /// "Spotify", or nil for a site that isn't listed.
    var safariEngineService: String? { ProtectedMedia.shared.service(of: page?.url) }

    /// The site plays in the other engine from now on; the page opens again there (and the card, which belonged to the
    /// old page, closes).
    var safariEngine: Binding<Bool> {
        Binding(get: { self.usesSafariEngine }, set: { [weak self] on in
            guard let self, let page = self.page, let c = self.controller, on != self.usesSafariEngine else { return }
            _ = c.closeSiteControls()
            c.setProtectedMediaEngine(on ? .webKit : .chromium, for: page)
        })
    }

    func clearData() {
        guard let page, let origin, let center, !clearing else { return }
        clearing = true
        let host = self.host
        center.engine.clearSiteData(origin: origin, in: page.profile, page: page) { [weak self, weak page] ok in
            guard let self else { return }
            self.clearing = false
            self.confirmingClear = false
            guard ok else { self.controller?.showToast("Couldn't clear the data of \(host)"); return }
            page?.reload()
            self.controller?.closeSiteControls()
            self.controller?.showToast("Cleared cookies and site data for \(host)")
        }
    }

    func openPopup(_ popup: BlockedPopup, always: Bool) {
        guard let page, let center else { return }
        center.engine.openBlockedPopup(popup, in: page, always: always)
        reloadActivity()
        if always { reloadPermissions() }
    }

    /// The site's pop-ups and redirects are allowed in this profile (its own setting or the default).
    var popupsAllowed: Bool { permissions[.popups]?.effective == .allow }

    /// "Always allow pop-ups for this site": from now on they open; the ones blocked so far stay listed to open.
    func allowPopups() {
        guard !popupsAllowed, set(.popups, to: .allow) else { return }
        controller?.showToast("Pop-ups from \(host) open from now on")
    }

    var siteSettingsURL: URL? { origin.flatMap { center?.engine.siteSettingsURL(origin: $0) } }

    func openSiteSettings() {
        guard let url = siteSettingsURL else { return }
        controller?.closeSiteControls()
        controller?.navigate(to: url, newTab: true)
    }

    /// The permission's choices as a native menu (keyboard and VoiceOver come free), under its button.
    func showMenu(for permission: SitePermission, in view: NSView) {
        guard let value = permissions[permission], !value.managed else { return }
        let menu = NSMenu()
        for state in permission.choices {
            let item = SiteMenuItem(title: state.title) { [weak self] in self?.set(permission, to: state) }
            item.state = value.state == state ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let def = SiteMenuItem(title: "Default") { [weak self] in self?.set(permission, to: .default) }
        def.state = value.state == .default ? .on : .off
        menu.addItem(def)
        let rect = menuAnchor?(permission) ?? NSRect(origin: view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil), size: .zero)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: view)
    }

    // MARK: Words

    var connectionText: String {
        switch security.level {
        case .secure: "Connection is secure"
        case .notSecure: "Connection is not secure"
        case .dangerous: "This site is dangerous"
        case .local: "Local connection"
        case .none: isWebsite ? "Connection unknown" : "Not a website"
        }
    }

    var connectionSymbol: String {
        switch security.level {
        case .secure: "lock.fill"
        case .notSecure: "lock.open.fill"
        case .dangerous: "exclamationmark.triangle.fill"
        case .local: "laptopcomputer"
        case .none: "globe"
        }
    }

    var connectionDetail: String {
        switch security.level {
        case .secure: security.hasMixedContent ? "Parts of this page, like images, aren't sent securely."
            : "What you send to this site is private when it gets there."
        case .notSecure: security.insecureForm ? "A form on this page sends what you type without encryption."
            : "Don't enter passwords or card numbers here: others on the network could see them."
        case .dangerous: "Attackers on this site might try to steal your information or install harmful software."
        case .local: "This page comes from this Mac."
        case .none: "This page isn't on the web."
        }
    }

    var zoomText: String { "\(Int((zoom * 100).rounded())) %" }
    /// Whose zoom it is: every page of the site (Chromium's host zoom), or this tab's own (a split pane, the dev engine).
    var zoomCaption: String { zoomScope == .site && isWebsite ? "This site" : "This tab" }

    var dataText: String {
        if counting && data == nil { return "Counting…" }
        guard let d = data else { return dataAvailable ? "Unknown" : "Not available in this engine" }
        if d.isEmpty { return "None in use" }
        var parts: [String] = []
        parts.append(d.cookies == 1 ? "1 cookie" : "\(d.cookies) cookies")
        if let b = d.storageBytes, b > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: b, countStyle: .file))
        } else if d.hasStorage {
            parts.append("storage")
        }
        return parts.joined(separator: " · ") + " in use"
    }

    var usingText: String? {
        var parts: [String] = []
        if activity.screen { parts.append("your screen") }
        if activity.camera { parts.append("your camera") }
        if activity.microphone { parts.append("your microphone") }
        if activity.location { parts.append("your location") }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "Using " + list
    }
}

/// A menu item that runs a closure.
private final class SiteMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: - The card

struct SiteControlsCard: View {
    @ObservedObject var model: SiteControlsModel
    /// Where each permission's button is (for its menu), in the card's coordinates.
    var reportMenuButton: (SitePermission, CGRect) -> Void = { _, _ in }
    var openMenu: (SitePermission) -> Void = { _ in }
    /// The card's height changed (More, the connection details, Clear's confirmation): the panel follows.
    var sizeChanged: (CGSize) -> Void = { _ in }
    private var ui: ResolvedTheme { model.ui }
    static let width: CGFloat = 300
    private let inset: CGFloat = AircSpacing.m

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.showsConnection { connection.padding(.top, AircSpacing.s) }
            if model.showsSafariEngine {
                divider
                safariEngineRow
            }
            if model.boostDomain != nil {
                divider
                boostRow
            }
            if let using = model.usingText { usingRow(using) }
            ForEach(model.systemRows, id: \.self) { systemRow($0) }
            if !model.activity.blockedPopups.isEmpty {
                divider
                popupsSection
            }
            if model.isWebsite {
                divider
                permissionsSection
            }
            divider
            zoomRow
            if model.isWebsite {
                divider
                dataSection
            }
            if model.siteSettingsURL != nil {
                divider
                footer
            }
        }
        .padding(.vertical, AircSpacing.m)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.onAppear { sizeChanged(g.size) }.onChange(of: g.size) { _, size in sizeChanged(size) }
        })
        .coordinateSpace(name: "siteControls")
        .testAnchorRoot()
        .aircTheme(ui)
    }

    private var divider: some View {
        Rectangle().fill(ui.surfaceBorder.color).frame(height: 0.5).padding(.vertical, AircSpacing.s)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let icon = model.favicon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
                } else {
                    Image(systemName: "globe").font(.system(size: 14, weight: .medium)).foregroundStyle(ui.surfaceTextSecondary.color)
                }
            }
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.tileFill.color))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.host).aircFont(AircFont.title3).foregroundStyle(ui.surfaceText.color)
                    .lineLimit(1).truncationMode(.middle)
                    .testAnchor("site.host")
                Button { model.showsConnection.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.connectionSymbol).font(.system(size: 10, weight: .semibold))
                        Text(model.connectionText).aircFont(AircFont.callout)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(model.showsConnection ? 90 : 0))
                    }
                    .foregroundStyle(model.security.level == .dangerous ? AircColor.destructive.color : ui.surfaceTextSecondary.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .testAnchor("site.connection")
            }
            Spacer(minLength: AircSpacing.s)
            iconButton("link", help: "Copy link", anchor: "site.copy") { model.copyLink() }
        }
        .padding(.horizontal, inset)
    }

    private func iconButton(_ symbol: String, help: String, anchor: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(ui.surfaceTextSecondary.color)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(SitePlateStyle(ui: ui, radius: 7))
        .help(help)
        .accessibilityLabel(help)
        .testAnchor(anchor)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.connectionDetail).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if model.security.hasCertificate {
                VStack(alignment: .leading, spacing: 3) {
                    if let s = model.security.subject { fact("Issued to", s) }
                    if let s = model.security.issuer { fact("Issued by", s) }
                    if let d = model.security.validTo { fact("Valid until", d.formatted(date: .abbreviated, time: .omitted)) }
                    if let p = model.security.protocolName { fact("Protocol", p) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.fieldFill.color))
        .padding(.horizontal, inset)
        .testAnchor("site.certificate")
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color).frame(width: 70, alignment: .leading)
            Text(value).aircFont(AircFont.callout).foregroundStyle(ui.surfaceText.color).lineLimit(2).textSelection(.enabled)
        }
    }

    private func usingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            // Red for a device in use, blue for the location alone (as the URL field's icons).
            Circle().fill(Color(nsColor: model.activity.isCapturing ? .systemRed : .systemBlue)).frame(width: 6, height: 6).frame(width: 20)
            Text(text).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
            Spacer(minLength: 0)
        }
        .frame(height: 28)
        .padding(.horizontal, inset)
        .padding(.top, AircSpacing.s)
        .testAnchor("site.using")
    }

    /// macOS keeps something from Airc that the site wants, where no permission row says it.
    private func systemRow(_ kind: SystemPrivacy.Kind) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .medium))
                .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 20, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.offText).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color).lineLimit(1)
                    .frame(height: 18)
                HStack(spacing: 4) {
                    Text("In macOS settings").aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Open Settings") { model.openSystemSettings(kind) }.buttonStyle(.airc(.plain, size: .small))
                        .help("System Settings → Privacy & Security")
                        .testAnchor("site.systemOpen.\(kind.rawValue)")
                }
                .frame(height: 24)
            }
        }
        .padding(.horizontal, inset)
        .padding(.top, AircSpacing.s)
        .testAnchor("site.system.\(kind.rawValue)")
    }

    /// The pop-ups the engine blocked on this page, each to open, and the site's switch to let them through from now on.
    private var popupsSection: some View {
        let popups = model.activity.blockedPopups
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.slash").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 20)
                Text(popups.count == 1 ? "Pop-up blocked" : "\(popups.count) pop-ups blocked")
                    .aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                    .testAnchor("site.popupsTitle")
                Spacer(minLength: 0)
            }
            .frame(height: 28)
            ForEach(popups, id: \.id) { p in
                HStack(spacing: 8) {
                    Text(p.url.isEmpty || p.url == "about:blank" ? "A blank page" : URLRules.displayURL(p.url))
                        .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                        .lineLimit(1).truncationMode(.middle)
                        .help(p.url)
                    Spacer(minLength: 4)
                    Button("Open") { model.openPopup(p, always: false) }.buttonStyle(.airc(.secondary, size: .small))
                        .testAnchor("site.popupOpen")
                }
                .frame(height: 28)
                .padding(.leading, 28)
                .testAnchor("site.popup")
            }
            Button { model.allowPopups() } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.popupsAllowed ? "checkmark" : "rectangle.on.rectangle").font(.system(size: 11, weight: .semibold))
                        .frame(width: 20)
                    Text(model.popupsAllowed ? "Pop-ups allowed for this site" : "Always allow pop-ups for this site").aircFont(AircFont.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ui.surfaceTextSecondary.color)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.popupsAllowed || !model.permissionsAvailable)
            .help("Pop-ups and redirects of \(model.host) open from now on, in this profile")
            .testAnchor("site.popupsAllow")
        }
        .padding(.horizontal, inset)
    }

    // MARK: Safari's engine

    /// Protected media: Safari's engine plays the site with Apple's FairPlay; what that means here.
    private var safariEngineRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "safari").font(.system(size: 13, weight: .medium))
                    .foregroundStyle((model.usesSafariEngine ? ui.accent : ui.surfaceTextSecondary).color).frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Safari's engine").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                    Text(model.usesSafariEngine ? "With Apple's FairPlay" : "Asked for protected media")
                        .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1)
                }
                Spacer(minLength: 4)
                AircSwitch(isOn: model.safariEngine)
                    .help(model.usesSafariEngine ? "Open this site with Chromium again" : "Open this site with Safari's engine")
                    .accessibilityLabel("Safari's engine")
                    .testAnchor("site.safariEngine")
            }
            .frame(height: 36)
            Text(model.usesSafariEngine
                 ? "\(model.safariEngineService ?? "This site")'s player needs DRM that Chromium can't offer without Google's certification. Here you sign in once, extensions don't run, and ⌥⌘I opens Web Inspector."
                 : "If it won't play (\"protected content\", \"browser not supported\"), Safari's engine may: it uses Apple's FairPlay.")
                .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28)
                .testAnchor("site.safariEngineWhy")
        }
        .padding(.horizontal, inset)
    }

    // MARK: Boost

    /// Arc's Boost entry: "Boost this site" opens the editor; a boosted site shows "Boosted", an on/off switch and Edit.
    @ViewBuilder private var boostRow: some View {
        if let boost = model.boost {
            HStack(spacing: 8) {
                Image(systemName: "paintbrush.pointed.fill").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle((boost.enabled ? ui.accent : ui.surfaceTextTertiary).color).frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(boost.enabled ? "Boosted" : "Boost Off").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                        .testAnchor("site.boostState")
                    Text(model.boostDomain ?? "").aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Edit") { model.openBoostEditor() }.buttonStyle(.airc(.secondary, size: .small))
                    .testAnchor("site.boostEdit")
                AircSwitch(isOn: model.boostEnabled)
                    .help(boost.enabled ? "Turn this site's Boost off" : "Turn this site's Boost on")
                    .testAnchor("site.boostSwitch")
            }
            .frame(height: 36)
            .padding(.horizontal, inset)
        } else {
            Button { model.openBoostEditor() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "paintbrush.pointed").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Boost this site").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                        Text("Colors, fonts, Zap and code").aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ui.surfaceTextTertiary.color)
                }
                .frame(height: 36)
                .padding(.horizontal, inset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .testAnchor("site.boost")
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Permissions").aircFont(AircFont.caption).foregroundStyle(ui.surfaceTextSecondary.color)
                if let p = model.profileName {
                    Text("· \(p) profile").aircFont(AircFont.caption).foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, inset)
            .frame(height: 26)
            if !model.permissionsAvailable {
                Text(model.usesSafariEngine ? "Safari's engine asks each time this site wants a permission, and keeps no settings for it."
                     : "The WebKit dev engine asks each time a site wants a permission and keeps no settings per site.")
                    .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, inset).padding(.top, 2)
                    .testAnchor("site.permissionsUnavailable")
            } else {
                ForEach(model.listed, id: \.self) { permissionRow($0) }
                if model.hasMore {
                    Button { withAircAnimation(AircSpring.row) { model.showsMore.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: model.showsMore ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                                .frame(width: 20)
                            Text(model.showsMore ? "Fewer Permissions" : "More Permissions").aircFont(AircFont.body)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(ui.surfaceTextSecondary.color)
                        .frame(height: 28)
                        .padding(.horizontal, inset)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .testAnchor("site.more")
                }
                Button { model.resetPermissions() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold)).frame(width: 20)
                        Text("Reset Permissions").aircFont(AircFont.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(ui.surfaceTextSecondary.color)
                    .frame(height: 28)
                    .padding(.horizontal, inset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.hasCustomPermissions)
                .opacity(model.hasCustomPermissions ? 1 : 0.4)
                .help("Every permission of this site back to the profile's default")
                .testAnchor("site.reset")
            }
        }
    }

    private func permissionRow(_ p: SitePermission) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            permissionLine(p)
            if model.systemBlocks(p), let kind = SystemPrivacy.Kind.allCases.first(where: { $0.permission == p }) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .semibold))
                    Text("Off in macOS").aircFont(AircFont.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Open Settings") { model.openSystemSettings(kind) }.buttonStyle(.airc(.plain, size: .small))
                        .help("System Settings → Privacy & Security → \(p.title)")
                        .testAnchor("site.systemOpen.\(kind.rawValue)")
                }
                .foregroundStyle(ui.surfaceTextSecondary.color)
                .frame(height: 24)
                .padding(.leading, 28 + inset)
                .padding(.trailing, inset)
                .padding(.bottom, 2)
                .testAnchor("site.system.\(kind.rawValue)")
            }
        }
    }

    private func permissionLine(_ p: SitePermission) -> some View {
        let value = model.permissions[p] ?? SitePermissionValue(state: .default, effective: .ask)
        return HStack(spacing: 8) {
            Image(systemName: p.symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 20)
            Text(p.title).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color).lineLimit(1)
            if isLive(p) {
                Circle().fill(Color(nsColor: p == .location ? .systemBlue : .systemRed)).frame(width: 5, height: 5).help("In use now")
            }
            Spacer(minLength: 4)
            Button { openMenu(p) } label: {
                HStack(spacing: 3) {
                    Text(value.effective.title).aircFont(AircFont.callout.weight(.medium))
                    if !value.managed { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)) }
                }
                .foregroundStyle(value.isCustom ? ui.surfaceText.color : ui.surfaceTextTertiary.color)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(value.isCustom ? ui.tileFill.color : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(SitePlateStyle(ui: ui, radius: 6))
            .disabled(value.managed)
            .help(value.managed ? "Set by your organisation" : value.isCustom ? "Set for this site" : "The profile's default")
            .accessibilityLabel("\(p.title): \(value.effective.title)")
            .background(GeometryReader { g in
                Color.clear.onAppear { reportMenuButton(p, g.frame(in: .named("siteControls"))) }
                    .onChange(of: g.frame(in: .named("siteControls"))) { _, f in reportMenuButton(p, f) }
            })
            .testAnchor("site.permission.\(p.rawValue)")
        }
        .frame(height: 30)
        .padding(.horizontal, inset)
    }

    private func isLive(_ p: SitePermission) -> Bool {
        (p == .camera && model.activity.camera) || (p == .microphone && model.activity.microphone)
            || (p == .location && model.activity.location)
    }

    // MARK: Zoom

    private var zoomRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.magnifyingglass").font(.system(size: 12, weight: .medium))
                .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text("Zoom").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                Text(model.zoomCaption).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                stepButton("minus", help: "Zoom Out ⌘−", anchor: "site.zoomOut") { model.zoom(step: -1) }
                Text(model.zoomText).aircFont(AircFont.callout.weight(.medium)).monospacedDigit()
                    .foregroundStyle(ui.surfaceText.color).frame(width: 46)
                    .testAnchor("site.zoomValue")
                stepButton("plus", help: "Zoom In ⌘+", anchor: "site.zoomIn") { model.zoom(step: 1) }
            }
            .background(Capsule(style: .continuous).fill(ui.fieldFill.color))
            let atDefault = abs(model.zoom - 1) < 0.001
            iconButton("arrow.counterclockwise", help: "Reset Zoom ⌘0", anchor: "site.zoomReset") { model.zoom(step: 0) }
                .disabled(atDefault)
                .opacity(atDefault ? 0.4 : 1)
        }
        .frame(height: 36)
        .padding(.horizontal, inset)
    }

    private func stepButton(_ symbol: String, help: String, anchor: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(ui.surfaceTextSecondary.color)
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(SitePlateStyle(ui: ui, radius: 12))
        .help(help)
        .accessibilityLabel(help)
        .testAnchor(anchor)
    }

    // MARK: Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Cookies and site data").aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                    Text(model.dataText).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color).lineLimit(1)
                        .testAnchor("site.dataText")
                }
                Spacer(minLength: 4)
                if model.dataAvailable && !model.confirmingClear {
                    Button("Clear…") { withAircAnimation(AircSpring.row) { model.confirmingClear = true } }
                        .buttonStyle(.airc(.secondary, size: .small))
                        .disabled(model.data?.isEmpty == true)
                        .testAnchor("site.clear")
                }
            }
            if model.confirmingClear {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Clear the cookies and data of \(model.host)? You may be signed out, and the page reloads.")
                        .aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("Cancel") { withAircAnimation(AircSpring.row) { model.confirmingClear = false } }
                            .buttonStyle(.airc(.plain, size: .small))
                            .testAnchor("site.clearCancel")
                        Button(model.clearing ? "Clearing…" : "Clear Site Data") { model.clearData() }
                            .buttonStyle(.airc(.destructive, size: .small))
                            .disabled(model.clearing)
                            .testAnchor("site.clearConfirm")
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.fieldFill.color))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, inset)
    }

    private var footer: some View {
        Button { model.openSiteSettings() } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium)).frame(width: 20)
                Text("All Site Settings").aircFont(AircFont.body)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(ui.surfaceTextSecondary.color)
            .frame(height: 28)
            .padding(.horizontal, inset)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .testAnchor("site.settings")
    }
}

/// A hover plate for the card's small buttons (`surfaceHover`, pressed a little darker), as the Command Bar's.
private struct SitePlateStyle: ButtonStyle {
    let ui: ResolvedTheme
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View { SitePlate(configuration: configuration, ui: ui, radius: radius) }
}

private struct SitePlate: View {
    let configuration: ButtonStyleConfiguration
    let ui: ResolvedTheme
    let radius: CGFloat
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(!enabled ? .clear : configuration.isPressed ? ui.surfaceText.alpha(0.09).color : hovered ? ui.surfaceHover.color : .clear))
            .onHover { hovered = $0 }
    }
}

// MARK: - The view

/// The card's NSView: `surface`, radius 14, the popover shadow, hanging from the URL field. First click works in a
/// window that isn't key; it never moves the window.
final class SiteControlsPanelView: NSView {
    let model: SiteControlsModel
    private var host: AircFirstClickHostingView<SiteControlsCard>!
    private var menuButtons: [SitePermission: CGRect] = [:]
    /// The card's size as SwiftUI last laid it out (NSHostingView's fittingSize reads zero from inside that layout).
    private var contentSize: CGSize = .zero
    private(set) var isClosing = false

    init(model: SiteControlsModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.popover
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = model.ui.surface.nsColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = model.ui.surfaceBorder.nsColor.cgColor
        layer?.applyAircShadow(.popover)
        var card = SiteControlsCard(model: model)
        card.reportMenuButton = { [weak self] p, r in self?.menuButtons[p] = r }
        card.openMenu = { [weak self] p in
            guard let self, let host = self.host else { return }
            self.model.showMenu(for: p, in: host)
        }
        card.sizeChanged = { [weak self] size in
            guard size.height > 1 else { return }
            // On the next turn: not from inside the hosting view's layout.
            DispatchQueue.main.async {
                guard let self, !self.isClosing, self.contentSize != size else { return }
                self.contentSize = size
                if self.model.controller?.siteControls === self { self.model.controller?.placeSiteControls() }
            }
        }
        host = AircFirstClickHostingView(rootView: card)
        // No safe-area insets (PromptBubbleView: a card made under the titlebar kept shifted hit regions).
        host.safeAreaRegions = []
        // The card's corners clip its content; the shadow stays on this view's layer.
        host.wantsLayer = true
        host.layer?.cornerRadius = AircRadius.popover
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        model.menuAnchor = { [weak self] p in self?.menuButtons[p] }
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var hostingView: NSView { host }

    /// Top-left at `origin` (the superview's flipped coordinates), sized to the card, at most `maxHeight` tall.
    func place(at origin: NSPoint, maxHeight: CGFloat) {
        let size = contentSize.height > 1 ? contentSize : host.fittingSize
        frame = NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: size.width, height: min(size.height, max(120, maxHeight)))
        host.frame = bounds
    }

    /// The URL field's slider button and its icons open and close the card themselves (on release), so a press on one
    /// isn't a click outside.
    static func isToggle(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if view is SiteIndicatorsView || view.superview is SiteIndicatorsView { return true }
        return view.superview is URLFieldView && (view as? GlyphButton)?.toolTip == "Site Controls"
    }

    /// Grows from the field's corner on the popover spring (Reduce Motion: a 150 ms fade).
    func present() {
        guard let layer else { return }
        if onMain({ AircMotion.prefersReducedMotion }) {
            layer.fade(from: 0, to: 1, duration: 0.15)
            return
        }
        // Layer-backed views anchor at their (flipped: top-left) corner, which is the field's.
        layer.add(AircSpring.grow.caAnimation(keyPath: "transform.scale", from: 0.94, to: 1), forKey: "grow")
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

// MARK: - The window's Site Controls

extension WindowController {
    private static var panelKey = 0
    private static var monitorKey = 0
    private static var observersKey = 0

    /// The card while it's open.
    var siteControls: SiteControlsPanelView? {
        get { objc_getAssociatedObject(self, &Self.panelKey) as? SiteControlsPanelView }
        set { objc_setAssociatedObject(self, &Self.panelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var siteControlsMonitor: Any? {
        get { objc_getAssociatedObject(self, &Self.monitorKey) }
        set { objc_setAssociatedObject(self, &Self.monitorKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var siteControlsObservers: [NSObjectProtocol] {
        get { objc_getAssociatedObject(self, &Self.observersKey) as? [NSObjectProtocol] ?? [] }
        set { objc_setAssociatedObject(self, &Self.observersKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The URL field's button and indicators.
    func toggleSiteControls() {
        if siteControls != nil { closeSiteControls(); return }
        showSiteControls()
    }

    /// Opens the card for the page on screen (the focused pane in a split).
    func showSiteControls() {
        guard let id = shownTabID, let page = engineTab(for: id), !page.isClosed else { return NSSound.beep() }
        Telemetry.shared.record(.featureUsed(.siteControlsOpened))
        closeSiteControls(animated: false)
        let center = SiteControlsCenter.shared
        center?.watch(page)
        let model = SiteControlsModel(page: page, center: center, ui: currentPalette.resolved,
                                      profileName: promptProfileName(for: page))
        model.controller = self
        let panel = SiteControlsPanelView(model: model)
        // Above the prompt card (which it covers while open), below the toast.
        if toast.superview === root { root.addSubview(panel, positioned: .below, relativeTo: toast) } else { root.addSubview(panel) }
        siteControls = panel
        placeSiteControls()
        panel.present()
        prompts.bubble?.isHidden = true
        observeSiteControls(panel)
    }

    /// Esc, a click outside, Copy link, the page going away. True when there was a card to close.
    @discardableResult
    func closeSiteControls(animated: Bool = true) -> Bool {
        guard let panel = siteControls else { return false }
        siteControls = nil
        if let m = siteControlsMonitor { NSEvent.removeMonitor(m) }
        siteControlsMonitor = nil
        siteControlsObservers.forEach(NotificationCenter.default.removeObserver)
        siteControlsObservers = []
        panel.dismiss(animated: animated)
        prompts.bubble?.isHidden = false
        return true
    }

    /// Under the URL field (where the permission prompts hang), or the page's top-left while the sidebar is hidden;
    /// inside the window.
    func placeSiteControls() {
        guard let panel = siteControls else { return }
        let anchor = promptAnchor()
        let rect = root.convert(anchor.rect, from: anchor.view)
        let x = min(max(8, rect.minX), max(8, root.bounds.width - SiteControlsCard.width - 8))
        let y = rect.maxY + PromptPresenter.gap
        panel.place(at: NSPoint(x: x, y: y), maxHeight: root.bounds.height - y - 8)
    }

    /// A URL field redrew: the card closes once the page on screen isn't the one it describes (a tab or Space switch,
    /// a split's other pane); a navigation of its own page keeps it, and it follows.
    func siteControlsPageChanged(in field: URLFieldView, to page: EngineTab?) {
        guard let panel = siteControls, !panel.isClosing else { return }
        let shown = shownTabID.flatMap { engineTab(for: $0) }
        if panel.model.page == nil || panel.model.page !== shown { closeSiteControls() }
    }

    /// ⌘+ ⌘− ⌘0 (Commands.swift): the card's percentage follows on engines that don't report zoom changes.
    func siteControlsDidZoom() {
        guard let page = shownTabID.flatMap({ engineTab(for: $0) }) else { return }
        SiteControlsCenter.shared?.pageChanged(page)
    }

    private func observeSiteControls(_ panel: SiteControlsPanelView) {
        let nc = NotificationCenter.default
        siteControlsObservers = [
            nc.addObserver(forName: SiteControlsCenter.didChange, object: nil, queue: .main) { [weak panel] note in
                guard let model = panel?.model, let page = model.page else { return }
                if let tab = note.userInfo?["tab"] as? EngineTab, tab !== page { return }
                if let dir = note.userInfo?["profile"] as? String, dir != page.profile.directory { return }
                model.reload()
            },
            nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak panel] _ in
                guard let self, panel != nil, self.siteControls === panel else { return }
                self.placeSiteControls()
            },
            nc.addObserver(forName: BoostCenter.didChange, object: nil, queue: .main) { [weak panel] _ in
                panel?.model.reloadBoost()
            },
            // Back from System Settings: what macOS allows Airc may have changed.
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak panel] _ in
                panel?.model.reloadSystem()
            },
            nc.addObserver(forName: ProtectedMedia.widevineAsked, object: nil, queue: .main) { [weak panel] note in
                guard let model = panel?.model, (note.object as? EngineTab) === model.page else { return }
                model.objectWillChange.send()
            },
        ]
        // A click anywhere else closes the card; the click still goes where it was aimed (as Arc's popovers).
        siteControlsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self, weak panel] event in
            guard let self, let panel, self.siteControls === panel else { return event }
            if event.window === self.window {
                if panel.bounds.contains(panel.convert(event.locationInWindow, from: nil)) { return event }
                let frame = self.window.contentView?.superview
                if SiteControlsPanelView.isToggle(frame?.hitTest(frame?.convert(event.locationInWindow, from: nil) ?? .zero)) { return event }
            }
            self.closeSiteControls()
            return event
        }
    }
}
