// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign

/// The URL field's small icons (SB-2), as Arc and Chrome show them: the page is using the screen, the camera or the
/// microphone (red, while the device is actually in use), it is using your location (blue, while a watch runs and
/// shortly after a read; SiteUse.swift), a pop-up was blocked, the site is boosted (BST-1), or the site has a setting
/// of its own (the Site Controls glyph stays, where its hover button
/// would be). A click opens Site Controls. They follow the engine's notifications through SiteControlsCenter; the field redraws them as it redraws
/// itself (URLFieldView.configure), and nothing polls.
final class SiteIndicatorsView: NSView {
    enum Kind: String { case screen, camera, microphone, location, popup, boost, custom }

    /// Shown now, left to right.
    private(set) var kinds: [Kind] = []
    private var buttons: [Kind: GlyphButton] = [:]
    private var palette: Palette?
    private var appliedPalette: Palette?
    private var hovered = false
    /// The page the icons describe (the URL field's).
    private(set) weak var page: EngineTab?
    private var observer: NSObjectProtocol?
    private var boostObserver: NSObjectProtocol?

    static let width: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        observer = NotificationCenter.default.addObserver(forName: SiteControlsCenter.didChange, object: nil, queue: .main) {
            [weak self] note in self?.changed(note)
        }
        boostObserver = NotificationCenter.default.addObserver(forName: BoostCenter.didChange, object: nil, queue: .main) {
            [weak self] _ in self?.update()
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        observer.map(NotificationCenter.default.removeObserver)
        boostObserver.map(NotificationCenter.default.removeObserver)
    }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var field: URLFieldView? { superview as? URLFieldView }
    private var controller: WindowController? { field?.controller }

    /// The page the field shows: its Space page's shown tab.
    private var shownPage: EngineTab? {
        guard let c = controller, let space = (field?.superview as? SpacePageView)?.spaceID,
              let id = c.displayedTabID(forSpace: space) else { return nil }
        return c.engineTab(for: id)
    }

    var isEmpty: Bool { visibleKinds.isEmpty }
    /// While the field's buttons show, the Site Controls button stands in for the "custom" glyph.
    private var visibleKinds: [Kind] { hovered ? kinds.filter { $0 != .custom } : kinds }

    /// The field redrew (a navigation, a tab or Space switch, a theme): requery the page's state.
    func refresh(palette: Palette) {
        self.palette = palette
        let page = shownPage
        if let field, let c = controller {
            c.siteControlsPageChanged(in: field, to: page)
            c.boostEditorPageChanged()
        }
        self.page = page
        update()
    }

    private func changed(_ note: Notification) {
        guard let page else { return }
        if let tab = note.userInfo?["tab"] as? EngineTab, tab !== page { return }
        if let dir = note.userInfo?["profile"] as? String, dir != page.profile.directory { return }
        update()
    }

    private func update() {
        let next = Self.kinds(for: page)
        guard next != kinds || palette != appliedPalette else { return }
        kinds = next
        appliedPalette = palette
        for kind in kinds where buttons[kind] == nil {
            let b = GlyphButton(symbol: Self.symbol(kind), size: 11)
            b.toolTip = Self.help(kind)
            b.setAccessibilityLabel(Self.help(kind))
            b.action = { [weak self] in self?.controller?.toggleSiteControls() }
            addSubview(b)
            buttons[kind] = b
        }
        for (kind, b) in buttons where !kinds.contains(kind) {
            b.removeFromSuperview()
            buttons[kind] = nil
        }
        for (kind, b) in buttons {
            b.tint = tint(for: kind)
            b.hoverFill = palette?.hover ?? .clear
        }
        field?.needsLayout = true
    }

    private func tint(for kind: Kind) -> NSColor {
        switch kind {
        case .screen, .camera, .microphone: NSColor.systemRed
        case .location: NSColor.systemBlue
        default: palette?.glyph ?? .secondaryLabelColor
        }
    }

    /// Lays the icons out so the last one ends at `maxX` (the field's coordinates); returns where the first begins.
    func place(endingAt maxX: CGFloat, hovered: Bool) -> CGFloat {
        self.hovered = hovered
        let shown = visibleKinds
        let w = CGFloat(shown.count) * Self.width
        let height = superview?.bounds.height ?? AircMetrics.Sidebar.urlFieldHeight
        frame = NSRect(x: maxX - w, y: 0, width: w, height: height)
        let b = AircMetrics.Sidebar.urlFieldButton
        for (kind, button) in buttons {
            guard let i = shown.firstIndex(of: kind) else { button.isHidden = true; continue }
            button.isHidden = false
            button.frame = NSRect(x: CGFloat(i) * Self.width + (Self.width - b) / 2, y: (height - b) / 2, width: b, height: b)
        }
        return maxX - w
    }

    // MARK: What to show

    static func kinds(for page: EngineTab?) -> [Kind] {
        guard let page, !page.isClosed, let center = SiteControlsCenter.shared else { return [] }
        center.watch(page)
        let a = center.activity(of: page)
        var k: [Kind] = []
        if a.screen { k.append(.screen) }
        if a.camera { k.append(.camera) }
        if a.microphone { k.append(.microphone) }
        if a.location { k.append(.location) }
        if let origin = SiteOrigin.of(page.url) {
            let p = center.permissions(origin: origin, in: page.profile)
            if !a.blockedPopups.isEmpty { k.append(.popup) }
            if BoostCenter.shared?.activeBoost(for: page.url) != nil { k.append(.boost) }
            if p.contains(where: { $0.value.isCustom }) { k.append(.custom) }
        } else if !a.blockedPopups.isEmpty {
            k.append(.popup)
        }
        return k
    }

    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .screen: "rectangle.inset.filled.and.person.filled"
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        case .popup: "rectangle.on.rectangle.slash"
        case .boost: "paintbrush.pointed.fill"
        case .custom: "slider.horizontal.3"
        }
    }

    static func help(_ kind: Kind) -> String {
        switch kind {
        case .screen: "This page is sharing your screen"
        case .camera: "This page is using your camera"
        case .microphone: "This page is using your microphone"
        case .location: "This page is using your location"
        case .popup: "Pop-up blocked"
        case .boost: "This site is boosted"
        case .custom: "Site Controls (this site has its own settings)"
        }
    }
}
