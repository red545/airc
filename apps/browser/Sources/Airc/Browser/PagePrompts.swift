// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

// SB-3: the prompts the engine asks the app to draw (engine/PROFILE-SERVICES.md "Page/window UI", PASS9-UI in
// engine/app-pass9.patch): a site's permission request (camera, microphone, location, notifications, clipboard…),
// Chromium's password save/update offer, and its address/card save offers. Arc shows Chrome's bubbles hanging from the
// URL bar; Airc draws its own card in the same place, under the sidebar's URL field (the page's top-left corner while
// the sidebar is hidden), and tells the engine that anchor so its own bubbles use it too.
//
// Each prompt belongs to the page that asked. Only the shown page's first prompt is on screen; a prompt of a page in
// the background waits for that page, and one of a page that goes to the background comes back with it (Chrome keeps
// them alive across tab switches). The engine withdraws a permission request when its page navigates or closes; the
// password offer goes with the page's next navigation; the autofill ones close when the engine says so.

/// One prompt as the app shows it. Values come from the engine's dictionaries; a password is never in them (only its
/// length), and nothing here is logged.
enum PagePrompt: Equatable {
    case permission(Permission)
    case password(Password)
    case autofill(Autofill)

    struct Permission: Equatable {
        let id: String
        let origin: String
        let kinds: [String]
    }

    struct Password: Equatable {
        /// "save" or "update".
        let state: String
        let origin: String
        var username: String
        let passwordLength: Int
        let usernames: [String]
        /// The page's URL when the offer came; its next navigation takes the offer away.
        let url: String
    }

    struct Autofill: Equatable {
        struct Change: Equatable { let field: String; let from: String; let to: String }
        let id: Int
        /// saveAddress, updateAddress or saveCard.
        let kind: String
        let title: String
        let message: String
        let accept: String
        let decline: String
        let footer: String
        let lines: [String]
        let changes: [Change]
    }

    init?(permission d: [String: Any]) {
        guard let id = d["id"] as? String else { return nil }
        self = .permission(Permission(id: id, origin: d["origin"] as? String ?? "", kinds: d["permissions"] as? [String] ?? []))
    }

    init?(password d: [String: Any], url: String) {
        guard let state = d["state"] as? String, state == "save" || state == "update" else { return nil }
        self = .password(Password(state: state, origin: d["origin"] as? String ?? "", username: d["username"] as? String ?? "",
                                  passwordLength: (d["passwordLength"] as? NSNumber)?.intValue ?? 0,
                                  usernames: d["usernames"] as? [String] ?? [], url: url))
    }

    init?(autofill d: [String: Any]) {
        guard let id = (d["id"] as? NSNumber)?.intValue, d["closed"] as? Bool != true, let kind = d["kind"] as? String else { return nil }
        let changes = (d["changes"] as? [[String: String]] ?? []).map {
            Autofill.Change(field: $0["field"] ?? "other", from: $0["from"] ?? "", to: $0["to"] ?? "")
        }
        self = .autofill(Autofill(id: id, kind: kind, title: d["title"] as? String ?? "", message: d["message"] as? String ?? "",
                                  accept: d["accept"] as? String ?? "Save", decline: d["decline"] as? String ?? "No thanks",
                                  footer: d["footer"] as? String ?? "", lines: d["lines"] as? [String] ?? [], changes: changes))
    }

    var origin: String {
        switch self {
        case .permission(let p): p.origin
        case .password(let p): p.origin
        case .autofill: ""
        }
    }

    /// For logs and checks: the kind, never a value.
    var label: String {
        switch self {
        case .permission(let p): "permission \(p.kinds.joined(separator: "+"))"
        case .password(let p): "password \(p.state)"
        case .autofill(let a): "autofill \(a.kind)"
        }
    }

    // MARK: Copy (Chrome's, so a site's instructions still match)

    /// "camera" → what the site wants to do, with its symbol.
    static func describe(_ kind: String) -> (text: String, symbol: String) {
        switch kind {
        case "camera": ("Use your camera", "video")
        case "microphone": ("Use your microphone", "mic")
        case "cameraPanTiltZoom": ("Move your camera", "arrow.up.and.down.and.arrow.left.and.right")
        case "location": ("Know your location", "location")
        case "notifications": ("Show notifications", "bell")
        case "clipboard": ("See text and images copied to the clipboard", "doc.on.clipboard")
        case "midi": ("Use your MIDI devices", "pianokeys")
        case "multipleDownloads": ("Download multiple files", "arrow.down.circle")
        case "localFonts": ("Use the fonts on this Mac", "textformat")
        case "idleDetection": ("Know when you're actively using this Mac", "figure.walk")
        case "storageAccess": ("Use cookies and site data", "externaldrive")
        case "windowManagement": ("Manage windows on all your displays", "macwindow.on.rectangle")
        case "fileSystem": ("Edit files on this Mac", "folder")
        case "keyboardLock": ("Use your keyboard", "keyboard")
        case "pointerLock": ("Hide and control your pointer", "cursorarrow")
        case "protocolHandler": ("Open links of this type", "link")
        case "sensors": ("Use your motion sensors", "gyroscope")
        case "localNetwork": ("Find and connect to devices on your local network", "network")
        case "vr": ("Use your virtual reality devices", "visionpro")
        case "ar": ("Create a 3D map of your surroundings", "arkit")
        case "handTracking": ("Track your hands", "hand.raised")
        case "identityProvider": ("Sign you in with an identity service", "person.badge.key")
        case "webAppInstallation": ("Install web apps", "square.and.arrow.down")
        case "capturedSurfaceControl": ("Scroll and zoom the tab you share", "rectangle.and.hand.point.up.left")
        case "diskQuota": ("Store more data on this Mac", "internaldrive")
        default: ("Use a feature of this Mac", "questionmark.circle")
        }
    }

    /// Kinds Chromium can grant for this visit only ("Allow this time"): the rest get Allow / Block.
    static let temporaryKinds: Set<String> = ["camera", "microphone", "cameraPanTiltZoom", "location"]

    /// "meet.google.com"; "This page" for a page without a host.
    static func displayHost(_ origin: String) -> String {
        guard let host = URL(string: origin)?.host, !host.isEmpty else { return "This page" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// What a prompt's buttons do.
enum PromptAnswer: Equatable {
    /// Permission: allow while visiting the site (`remember`) or this time only.
    case allow(remember: Bool)
    /// Permission: never allow (a persisted block).
    case block
    /// Password: save (with an edited username) or update.
    case save(username: String?)
    /// Password "Never" (save) / "Not now" (update); autofill's decline.
    case never
    /// Autofill: accept.
    case accept
    /// The × (and the page or tab going away).
    case dismiss
}

// MARK: - The card

final class PromptCardModel: ObservableObject {
    @Published var prompt: PagePrompt
    @Published var username: String
    let profileName: String?
    let ui: ResolvedTheme
    var onAnswer: ((PromptAnswer) -> Void)?

    init(prompt: PagePrompt, profileName: String?, ui: ResolvedTheme) {
        self.prompt = prompt
        if case .password(let p) = prompt { username = p.username } else { username = "" }
        self.profileName = profileName
        self.ui = ui
    }
}

struct PromptCard: View {
    @ObservedObject var model: PromptCardModel
    private var ui: ResolvedTheme { model.ui }
    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.prompt {
            case .permission(let p): permission(p)
            case .password(let p): password(p)
            case .autofill(let a): autofill(a)
            }
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .testAnchorRoot()
        .aircTheme(ui)
    }

    private func header(_ symbol: String, title: String, subtitle: String?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(ui.surfaceText.color)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.tileFill.color))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).aircFont(AircFont.title3).foregroundStyle(ui.surfaceText.color)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color).lineLimit(1)
                }
            }
            // Room for the × (PromptBubbleView's own button).
            Spacer(minLength: 26)
        }
    }

    // MARK: Permission

    @ViewBuilder private func permission(_ p: PagePrompt.Permission) -> some View {
        let kinds = p.kinds.isEmpty ? ["unknown"] : p.kinds
        header(PagePrompt.describe(kinds[0]).symbol, title: "\(PagePrompt.displayHost(p.origin)) wants to",
               subtitle: model.profileName.map { "In the \($0) profile" })
        VStack(alignment: .leading, spacing: 6) {
            ForEach(kinds, id: \.self) { k in
                let d = PagePrompt.describe(k)
                HStack(spacing: 8) {
                    Image(systemName: d.symbol).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 18)
                    Text(d.text).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 12)
        if Set(kinds).isSubset(of: PagePrompt.temporaryKinds) {
            VStack(spacing: 6) {
                wide("Allow while visiting the site", anchor: "prompt.allow") { model.onAnswer?(.allow(remember: true)) }
                wide("Allow this time", anchor: "prompt.allowOnce") { model.onAnswer?(.allow(remember: false)) }
                wide("Never allow", anchor: "prompt.block") { model.onAnswer?(.block) }
            }
            .padding(.top, 14)
        } else {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Block") { model.onAnswer?(.block) }
                    .buttonStyle(.airc(.secondary)).testAnchor("prompt.block")
                Button("Allow") { model.onAnswer?(.allow(remember: true)) }
                    .buttonStyle(.airc(.primary)).testAnchor("prompt.allow")
            }
            .padding(.top, 14)
        }
    }

    private func wide(_ title: String, anchor: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(.airc(.secondary))
            .testAnchor(anchor)
    }

    // MARK: Password

    @ViewBuilder private func password(_ p: PagePrompt.Password) -> some View {
        let update = p.state == "update"
        header("key.fill", title: update ? "Update password?" : "Save password?",
               subtitle: [PagePrompt.displayHost(p.origin), model.profileName.map { "\($0) profile" }].compactMap { $0 }.joined(separator: " · "))
        VStack(spacing: 8) {
            if update {
                field(symbol: "person", Text(model.username.isEmpty ? "No username" : model.username))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "person").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 16)
                    TextField("Username", text: $model.username)
                        .textFieldStyle(.plain)
                        .aircFont(AircFont.body)
                        .foregroundStyle(ui.surfaceText.color)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: AircRadius.control, style: .continuous).fill(ui.fieldFill.color))
                .testAnchor("prompt.username")
            }
            field(symbol: "lock", Text(String(repeating: "•", count: max(6, min(p.passwordLength, 18)))).tracking(1))
        }
        .padding(.top, 12)
        HStack(spacing: 8) {
            Button(update ? "Not now" : "Never") { model.onAnswer?(.never) }
                .buttonStyle(.airc(.plain)).testAnchor("prompt.never")
            Spacer(minLength: 0)
            Button(update ? "Update" : "Save") {
                model.onAnswer?(.save(username: update || model.username == p.username ? nil : model.username))
            }
            .buttonStyle(.airc(.primary)).testAnchor("prompt.save")
        }
        .padding(.top, 14)
    }

    private func field(symbol: String, _ text: Text) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(ui.surfaceTextSecondary.color).frame(width: 16)
            text.aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: AircRadius.control, style: .continuous).fill(ui.fieldFill.color))
    }

    // MARK: Address and card

    @ViewBuilder private func autofill(_ a: PagePrompt.Autofill) -> some View {
        header(a.kind == "saveCard" ? "creditcard" : "mappin.and.ellipse",
               title: a.title.isEmpty ? (a.kind == "saveCard" ? "Save card?" : "Save address?") : a.title,
               subtitle: model.profileName.map { "In the \($0) profile" })
        if !a.message.isEmpty {
            Text(a.message).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
        if !a.lines.isEmpty || !a.changes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(a.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(a.changes.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(c.to).aircFont(AircFont.body).foregroundStyle(ui.surfaceText.color)
                        if !c.from.isEmpty {
                            Text(c.from).aircFont(AircFont.callout).strikethrough().foregroundStyle(ui.surfaceTextTertiary.color)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ui.fieldFill.color))
            .padding(.top, 10)
        }
        if !a.footer.isEmpty {
            Text(a.footer).aircFont(AircFont.callout).foregroundStyle(ui.surfaceTextTertiary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        }
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(a.decline) { model.onAnswer?(.never) }.buttonStyle(.airc(.secondary)).testAnchor("prompt.decline")
            Button(a.accept) { model.onAnswer?(.accept) }.buttonStyle(.airc(.primary)).testAnchor("prompt.accept")
        }
        .padding(.top, 14)
    }
}

/// The card's NSView: the `surface` panel with the popover shadow, hanging from the anchor. It takes the first click
/// (a window that isn't key yet still answers), and never moves the window.
final class PromptBubbleView: NSView {
    let model: PromptCardModel
    private let host: AircFirstClickHostingView<PromptCard>
    /// The ×, an AppKit button over the card's top-right corner: SwiftUI took no clicks on a button there (its hit
    /// regions near the card's top were offset from what it drew; checked by a hit map, 2026-11-06).
    let closeButton = GlyphButton(symbol: "xmark", size: 10)

    init(model: PromptCardModel) {
        self.model = model
        host = AircFirstClickHostingView(rootView: PromptCard(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = model.ui.surface.nsColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = model.ui.surfaceBorder.nsColor.cgColor
        layer?.applyAircShadow(.popover)
        // No safe-area insets: made at the window's top-left (under the titlebar) before it's placed, the card's
        // controls kept hit regions shifted by the titlebar's inset.
        host.safeAreaRegions = []
        addSubview(host)
        closeButton.tint = model.ui.surfaceTextSecondary.nsColor
        closeButton.hoverFill = model.ui.surfaceHover.nsColor
        closeButton.toolTip = "Close"
        closeButton.setAccessibilityLabel("Close")
        closeButton.action = { [weak model] in model?.onAnswer?(.dismiss) }
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var hostingView: NSView { host }

    /// Top-left at `origin` (in the superview's flipped coordinates), sized to the card.
    func place(at origin: NSPoint) {
        let size = host.fittingSize
        frame = NSRect(x: origin.x.rounded(), y: origin.y.rounded(), width: size.width, height: size.height)
        host.frame = bounds
        closeButton.frame = NSRect(x: bounds.width - 10 - 22, y: 10, width: 22, height: 22)
    }

    /// Drops 6 pt and fades in on the dialog curve.
    func present() {
        guard let layer else { return }
        let curve = AircCurve.dialog
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = -6
        drop.toValue = 0
        drop.duration = curve.duration
        drop.timingFunction = curve.timingFunction
        layer.add(drop, forKey: "drop")
        layer.fade(from: 0, to: 1, duration: 0.15)
    }
}

// MARK: - Presenter (one per window)

/// What a window gives its prompts.
protocol PromptHost: AnyObject {
    /// The view the card is added to (flipped, the window's root).
    var promptRoot: NSView { get }
    /// The view the card goes under: the card is inserted below it (the toast).
    var promptSibling: NSView? { get }
    var promptEngineWindow: EngineWindow { get }
    /// The page on screen, if any.
    var promptShownPage: EngineTab? { get }
    /// The URL field (or, without one on screen, a small rectangle at the page's top-left) and its rectangle.
    func promptAnchor() -> (view: NSView, rect: NSRect)
    var promptTheme: ResolvedTheme { get }
    func promptProfileName(for page: EngineTab) -> String?
    func promptOwns(_ page: EngineTab) -> Bool
    func promptToast(_ text: String)
}

final class PromptPresenter {
    unowned let host: PromptHost
    weak var center: PromptCenter?
    /// Per page, in arrival order.
    private var queues: [ObjectIdentifier: (page: EngineTab, prompts: [PagePrompt])] = [:]
    private(set) var bubble: PromptBubbleView?
    /// The prompt on screen and its page.
    private(set) var shown: (page: ObjectIdentifier, prompt: PagePrompt)?
    /// The gap between the URL field and the card.
    static let gap: CGFloat = 6
    /// Saved logins to choose from, under the page's field (PasswordPicker.swift).
    private(set) lazy var passwords: PasswordPicker = {
        let picker = PasswordPicker(host: host)
        picker.accept = { [weak self] page, index in self?.center?.acceptPassword(index, page: page) ?? false }
        picker.dismiss = { [weak self] page in self?.center?.hidePasswords(page: page) }
        return picker
    }()

    init(host: PromptHost) { self.host = host }

    func prompts(for page: EngineTab) -> [PagePrompt] { queues[ObjectIdentifier(page)]?.prompts ?? [] }
    var pendingCount: Int { queues.values.reduce(0) { $0 + $1.prompts.count } }

    /// A new prompt for `page`. One password offer and one autofill offer per page at a time: a newer one replaces it.
    func add(_ prompt: PagePrompt, for page: EngineTab) {
        let key = ObjectIdentifier(page)
        var list = queues[key]?.prompts ?? []
        switch prompt {
        case .permission(let p): if list.contains(where: { if case .permission(let q) = $0 { q.id == p.id } else { false } }) { return }
        case .password: list.removeAll { if case .password = $0 { true } else { false } }
        case .autofill: list.removeAll { if case .autofill = $0 { true } else { false } }
        }
        list.append(prompt)
        queues[key] = (page, list)
        refresh()
    }

    /// Takes away prompts the engine withdrew (or that went with their page), without answering them.
    func withdraw(where match: (PagePrompt) -> Bool) {
        var changed = false
        for (key, entry) in queues {
            let kept = entry.prompts.filter { !match($0) }
            if kept.count != entry.prompts.count {
                changed = true
                queues[key] = kept.isEmpty ? nil : (entry.page, kept)
            }
        }
        if changed { refresh() }
    }

    /// The page closed or left this window: its prompts go, dismissed.
    func dropAll(for page: EngineTab) {
        guard let entry = queues.removeValue(forKey: ObjectIdentifier(page)) else { return }
        entry.prompts.forEach { center?.resolve($0, page: page, answer: .dismiss) }
        refresh()
    }

    /// The window is closing.
    func dropAll() {
        passwords.close()
        let all = queues
        queues = [:]
        for entry in all.values { entry.prompts.forEach { center?.resolve($0, page: entry.page, answer: .dismiss) } }
        refresh()
    }

    /// A page committed a new URL: a password offer made for the previous one goes (Chrome closes its bubble then).
    func pageNavigated(_ page: EngineTab) {
        guard let entry = queues[ObjectIdentifier(page)], let url = page.url?.absoluteString else { return }
        let stale = entry.prompts.filter { if case .password(let p) = $0 { p.url != url } else { false } }
        guard !stale.isEmpty else { return }
        stale.forEach { center?.resolve($0, page: page, answer: .dismiss) }
        withdraw { stale.contains($0) }
    }

    /// Shows the shown page's first prompt (or hides the card): after a tab, Space or window change.
    func refresh() {
        // The password list belongs to the page on screen.
        if let p = passwords.page, p !== host.promptShownPage { passwords.close() }
        guard let page = host.promptShownPage, !page.isClosed,
              var entry = queues[ObjectIdentifier(page)], !entry.prompts.isEmpty else { return hide() }
        // A password offer the engine no longer has (the page moved on while it was in the background) goes.
        if let center, case .password = entry.prompts[0], !center.passwordOfferStands(on: page) {
            entry.prompts.removeFirst()
            queues[ObjectIdentifier(page)] = entry.prompts.isEmpty ? nil : entry
            return refresh()
        }
        let prompt = entry.prompts[0]
        let key = ObjectIdentifier(page)
        if let s = shown, s.page == key, s.prompt == prompt, bubble != nil { return layout() }
        hide(animated: false)
        let model = PromptCardModel(prompt: prompt, profileName: host.promptProfileName(for: page), ui: host.promptTheme)
        model.onAnswer = { [weak self, weak page] answer in
            guard let self, let page else { return }
            self.answer(answer, prompt: prompt, page: page)
        }
        let b = PromptBubbleView(model: model)
        if let sibling = host.promptSibling, sibling.superview === host.promptRoot {
            host.promptRoot.addSubview(b, positioned: .below, relativeTo: sibling)
        } else {
            host.promptRoot.addSubview(b)
        }
        bubble = b
        shown = (key, prompt)
        layout()
        b.present()
        // The page is waiting for an answer: Site Controls, open in the same place, makes way.
        (host as? WindowController)?.closeSiteControls()
    }

    /// Follows the anchor (window resize, sidebar hide/show, Space switch). Through the engine's own conversion of its
    /// UI anchor, so the card and the engine's bubbles agree.
    func layout() {
        passwords.layout()
        guard let b = bubble else { return }
        let anchor = host.promptAnchor()
        let root = host.promptRoot
        var rect = root.convert(anchor.rect, from: anchor.view)
        if let center, let screen = center.engineAnchor(window: host.promptEngineWindow, view: anchor.view, rect: anchor.rect),
           screen.width > 0, let w = root.window {
            rect = root.convert(w.convertFromScreen(screen), from: nil)
        }
        // Flipped root: the card's top is the anchor's bottom edge plus the gap; it stays inside the window.
        let x = min(max(8, rect.minX), max(8, root.bounds.width - PromptCard.width - 8))
        b.place(at: NSPoint(x: x, y: rect.maxY + Self.gap))
    }

    /// The anchor's rectangle in the root view (for checks).
    func anchorRectInRoot() -> NSRect {
        let a = host.promptAnchor()
        return host.promptRoot.convert(a.rect, from: a.view)
    }

    private func hide(animated: Bool = true) {
        shown = nil
        guard let b = bubble else { return }
        bubble = nil
        guard animated else { return b.removeFromSuperview() }
        b.layer?.fade(from: 1, to: 0, duration: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { b.removeFromSuperview() }
    }

    private func answer(_ answer: PromptAnswer, prompt: PagePrompt, page: EngineTab) {
        let key = ObjectIdentifier(page)
        if var entry = queues[key], let i = entry.prompts.firstIndex(of: prompt) {
            entry.prompts.remove(at: i)
            queues[key] = entry.prompts.isEmpty ? nil : entry
        }
        center?.resolve(prompt, page: page, answer: answer)
        if case .password = prompt, case .save = answer { host.promptToast("Password saved") }
        refresh()
    }
}

// MARK: - Center (the app's routing)

/// Routes the engine's prompts to the window that shows their page, and answers them. Only the Chromium engine asks.
final class PromptCenter {
    private var presenters: [() -> PromptPresenter?] = []
    #if AIRC_TESTING
    /// Every answer, in order (kind and answer only), for the scripted checks.
    private(set) var answered: [(label: String, answer: PromptAnswer)] = []
    #endif
    #if canImport(AircCore)
    private weak var engine: ChromiumEngine?
    #endif

    init(engine: BrowserEngine) {
        #if canImport(AircCore)
        guard let chromium = engine as? ChromiumEngine else { return }
        self.engine = chromium
        chromium.permissionRequested = { [weak self] page, request in
            guard let prompt = PagePrompt(permission: request) else { return }
            self?.deliver(prompt, page: page, attempt: 0)
        }
        chromium.permissionRequestDismissed = { [weak self] id in
            self?.each { $0.withdraw { if case .permission(let p) = $0 { p.id == id } else { false } } }
        }
        chromium.passwordPromptDidChange = { [weak self] page, d in
            if d["state"] as? String == "saved" { return }
            guard let prompt = PagePrompt(password: d, url: page.url?.absoluteString ?? "") else { return }
            self?.deliver(prompt, page: page, attempt: 0)
        }
        // Several saved logins: the app's list replaces Chromium's popup (engine pass 12). Rows go to the window
        // showing the page; a page no window shows gets none.
        chromium.usesHostPasswordSuggestions = true
        chromium.autofillSuggestionsDidChange = { [weak self, weak chromium] page, items in
            guard let self else { return }
            if let p = self.presenters.compactMap({ $0() }).first(where: { $0.host.promptOwns(page) }) {
                p.passwords.update(items, page: page)
            } else if !items.isEmpty {
                chromium?.hideAutofillSuggestions(in: page)
            }
        }
        chromium.autofillPromptDidChange = { [weak self] page, d in
            if d["closed"] as? Bool == true, let id = (d["id"] as? NSNumber)?.intValue {
                self?.each { $0.withdraw { if case .autofill(let a) = $0 { a.id == id } else { false } } }
                return
            }
            guard let prompt = PagePrompt(autofill: d) else { return }
            self?.deliver(prompt, page: page, attempt: 0)
        }
        #endif
    }

    func register(_ presenter: PromptPresenter) {
        presenter.center = self
        presenters.removeAll { $0() == nil }
        presenters.append { [weak presenter] in presenter }
    }

    private func each(_ body: (PromptPresenter) -> Void) {
        presenters.compactMap { $0() }.forEach(body)
    }

    /// To the window whose tab this page is. A page that just arrived (a popup) is adopted on the next turn, so an
    /// owner is looked for again for up to 2 s; a page nobody shows is answered with dismiss.
    private func deliver(_ prompt: PagePrompt, page: EngineTab, attempt: Int) {
        if let p = presenters.compactMap({ $0() }).first(where: { $0.host.promptOwns(page) }) {
            return p.add(prompt, for: page)
        }
        guard attempt < 20, !page.isClosed else { return resolve(prompt, page: page, answer: .dismiss) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak page] in
            guard let page else { return }
            self?.deliver(prompt, page: page, attempt: attempt + 1)
        }
    }

    /// Tells the engine. Each prompt is answered once (the presenter has already taken it off its queue).
    func resolve(_ prompt: PagePrompt, page: EngineTab, answer: PromptAnswer) {
        #if AIRC_TESTING
        answered.append((prompt.label, answer))
        #endif
        #if canImport(AircCore)
        guard let engine else { return }
        switch prompt {
        case .permission(let p):
            switch answer {
            case .allow(let remember): engine.resolvePermission(p.id, result: "accept", remember: remember)
            case .block: engine.resolvePermission(p.id, result: "deny", remember: true)
            default: engine.resolvePermission(p.id, result: "dismiss", remember: false)
            }
        case .password(let p):
            let action: String
            switch answer {
            case .save: action = p.state
            case .never: action = p.state == "update" ? "nope" : "never"
            default: action = "dismiss"
            }
            var username: String?
            if case .save(let edited) = answer { username = edited }
            engine.resolvePasswordPrompt(in: page, action: action, username: username)
        case .autofill(let a):
            let action = answer == .accept ? "accept" : answer == .never ? "decline" : "dismiss"
            engine.resolveAutofillPrompt(in: page, id: a.id, action: action)
        }
        #endif
    }

    /// Fills the saved login behind `index` (the engine's handle). False: stale, too soon after the list showed, or the
    /// field changed.
    func acceptPassword(_ index: Int, page: EngineTab) -> Bool {
        #if canImport(AircCore)
        return engine?.acceptAutofillSuggestion(in: page, index: index) ?? false
        #else
        return false
        #endif
    }

    func hidePasswords(page: EngineTab) {
        #if canImport(AircCore)
        engine?.hideAutofillSuggestions(in: page)
        #endif
    }

    /// The engine still offers to save or update a password on `page`.
    func passwordOfferStands(on page: EngineTab) -> Bool {
        #if canImport(AircCore)
        guard let engine else { return false }
        let state = engine.passwordPrompt(for: page)?["state"] as? String
        return state == "save" || state == "update"
        #else
        return false
        #endif
    }

    /// Sets the engine's UI anchor (its own bubbles hang there too) and returns it in screen coordinates.
    func engineAnchor(window: EngineWindow, view: NSView, rect: NSRect) -> NSRect? {
        #if canImport(AircCore)
        guard let engine, view.window === window.window else { return nil }
        engine.setUIAnchor(window: window, view: view, rect: rect)
        return engine.uiAnchorRectInScreen(window: window)
        #else
        return nil
        #endif
    }
}
