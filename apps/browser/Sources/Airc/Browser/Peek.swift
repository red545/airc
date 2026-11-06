// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// PK-1 Peek (spec §2.16b): a link opens in a card over the page instead of a new tab. Today: ⇧-click on any link, and
/// a link a pinned tab or Favorite opens in a new tab to another site (the engine's routing policy hands both over;
/// engine/FEATURES-V1.md). The page is an ordinary live tab of the opener's profile (`EngineWindow.openPeek`). ⌘O or the
/// expand button makes it a Today tab (the same page, no reload); a click outside, ✕, Esc or ⌘W closes it (its
/// "Leave site?" still asks); ⌘Z or ⇧⌘T right after brings it back. Settings → Links can turn it off.
final class PeekOverlayView: NSView {
    let scrim = NSView()
    let card = NSView()
    let toolbar = NSView()
    let titleLabel = NSTextField(labelWithString: "")
    let expandButton = GlyphButton(symbol: "arrow.up.left.and.arrow.down.right", size: 12)
    /// PK-1 → SV-1: the page and the one under the card side by side.
    let splitButton = GlyphButton(symbol: "rectangle.split.2x1", size: 12)
    let closeButton = GlyphButton(symbol: "xmark", size: 12)
    /// The engine attaches the page here.
    let pageHost = PageHostView()
    var onClose: (() -> Void)?
    var onPromote: (() -> Void)?
    var onSplit: (() -> Void)?
    static let toolbarHeight: CGFloat = 34

    init(palette: Palette) {
        super.init(frame: .zero)
        wantsLayer = true
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(palette.isDark ? 0.40 : 0.20).cgColor
        scrim.layer?.cornerRadius = AircMetrics.Window.cardRadius
        addSubview(scrim)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = palette.resolved.surface.nsColor.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = palette.resolved.surfaceBorder.nsColor.cgColor
        card.layer?.applyAircShadow(.panel)
        addSubview(card)
        card.addSubview(toolbar)
        card.addSubview(pageHost)
        pageHost.wantsLayer = true
        pageHost.layer?.masksToBounds = true
        pageHost.layer?.cornerRadius = 12
        pageHost.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        titleLabel.font = AircFont.urlField.nsFont
        titleLabel.textColor = palette.resolved.surfaceTextSecondary.nsColor
        titleLabel.lineBreakMode = .byTruncatingTail
        toolbar.addSubview(titleLabel)
        for b in [splitButton, expandButton, closeButton] {
            b.tint = palette.resolved.surfaceTextSecondary.nsColor
            b.hoverFill = palette.resolved.surfaceHover.nsColor
            toolbar.addSubview(b)
        }
        expandButton.toolTip = "Open as a tab (⌘O)"
        splitButton.toolTip = "Open in Split View"
        closeButton.toolTip = "Close (Esc)"
        expandButton.action = { [weak self] in self?.onPromote?() }
        splitButton.action = { [weak self] in self?.onSplit?() }
        closeButton.action = { [weak self] in self?.onClose?() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Over the page card, the card inset from it.
    func layoutIn(page: NSRect) {
        frame = page
        scrim.frame = bounds
        let insetX = max(24, (bounds.width * 0.07).rounded()), insetY = max(20, (bounds.height * 0.05).rounded())
        card.frame = bounds.insetBy(dx: insetX, dy: insetY)
        let h = Self.toolbarHeight, w = card.bounds.width, s: CGFloat = 24
        // The card isn't flipped: the toolbar is at its top.
        toolbar.frame = NSRect(x: 0, y: card.bounds.height - h, width: w, height: h)
        closeButton.frame = NSRect(x: w - 8 - s, y: (h - s) / 2, width: s, height: s)
        expandButton.frame = closeButton.frame.offsetBy(dx: -s - 2, dy: 0)
        splitButton.frame = expandButton.frame.offsetBy(dx: -s - 2, dy: 0)
        titleLabel.frame = NSRect(x: 14, y: (h - 16) / 2, width: max(0, splitButton.frame.minX - 22), height: 16)
        pageHost.frame = NSRect(x: 0, y: 0, width: w, height: max(0, card.bounds.height - h))
    }

    /// The scrim's presses are the overlay's (it takes the first click in a window that isn't key).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === scrim ? self : v
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    func present() {
        guard let layer = card.layer else { return }
        let curve = AircCurve.dialog
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.96
        grow.toValue = 1
        grow.duration = curve.duration
        grow.timingFunction = curve.timingFunction
        layer.add(grow, forKey: "grow")
        self.layer?.fade(from: 0, to: 1, duration: 0.15)
    }
}

extension WindowController {
    struct Peek {
        let page: EngineTab
        let view: PeekOverlayView
        let openerTabID: String?
        /// Closing was asked for; waiting for the page's unload handlers.
        var closing = false
    }

    /// Whether a link the engine is about to open should open in Peek instead (called synchronously from the routing
    /// policy; the Peek itself opens on the next turn).
    func wantsPeek(_ request: EngineLinkRequest) -> Bool {
        guard app?.settings.values.peekEnabled ?? true, request.source == "page", request.userGesture,
              let opener = request.opener, let openerID = tabID(for: opener), peek?.page !== opener else { return false }
        // ⇧-click (Chromium asks for a new window).
        if request.disposition == "window" { return true }
        // A pinned tab or Favorite opening another site in a new tab.
        let pinned = store.tab(openerID)?.itemID != nil
        return pinned && (request.disposition == "current_tab" || (request.disposition == "foreground_tab" && Self.crossSite(opener.url, request.url)))
    }

    /// Different sites: the last two labels of the host (or the whole host for an IP address or a one-label host).
    static func crossSite(_ a: URL?, _ b: URL) -> Bool {
        func site(_ u: URL?) -> String {
            guard let h = u?.host?.lowercased() else { return "" }
            if h.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return h }
            return h.split(separator: ".").suffix(2).joined(separator: ".")
        }
        return site(a) != site(b)
    }

    func openPeek(_ url: URL, from opener: EngineTab) {
        Telemetry.shared.record(.featureUsed(.peekOpen))
        if let p = peek { finishPeek(p) }
        let view = PeekOverlayView(palette: currentPalette)
        root.addSubview(view, positioned: .below, relativeTo: toast)
        view.layoutIn(page: card.frame)
        do {
            let page = try engineWindow.openPeek(url: url, opener: opener, in: view.pageHost)
            page.delegate = self
            peek = Peek(page: page, view: view, openerTabID: tabID(for: opener))
            view.titleLabel.stringValue = URLRules.displayHost(url.absoluteString)
            view.onClose = { [weak self] in self?.closePeek() }
            view.onPromote = { [weak self] in self?.promotePeek() }
            view.onSplit = { [weak self] in self?.splitPeek() }
            view.present()
            page.focus()
        } catch {
            // An engine without Peek: a new tab, as before.
            view.removeFromSuperview()
            navigate(to: url, newTab: true)
        }
    }

    /// ✕, Esc, ⌘W, a click outside. The page's unload handlers run first; a page that asks keeps the card until it
    /// has closed.
    func closePeek() {
        guard var p = peek, !p.closing else { return }
        p.closing = true
        peek = p
        recentlyClosedPeek = (p.page.url, store.undoStack.count, Date())
        p.page.close()
        if p.page.isClosed { finishPeek(p) }
    }

    /// The engine closed the Peek's page (after its unload handlers).
    func peekPageClosed(_ page: EngineTab) {
        guard let p = peek, p.page === page else { return }
        finishPeek(p)
    }

    private func finishPeek(_ p: Peek) {
        if peek?.page === p.page { peek = nil }
        p.view.onClose = nil
        p.view.onPromote = nil
        p.view.onSplit = nil
        p.view.layer?.fade(from: 1, to: 0, duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { p.view.removeFromSuperview() }
        if let id = shownTabID { engineTab(for: id)?.focus() }
    }

    /// ⌘O and the expand button: the same page becomes a Today tab after its opener.
    func promotePeek() {
        guard let p = peek, !p.closing, !p.page.isClosed else { return }
        let url = p.page.url?.absoluteString ?? "about:blank"
        guard let t = try? store.openTab(url: url, inSpace: currentSpaceID, openerID: p.openerTabID, title: p.page.title) else { return }
        Telemetry.shared.record(.featureUsed(.peekPromote))
        peek = nil
        adopt(p.page, as: t.id)
        show(t.id)
        p.view.removeFromSuperview()
        scheduleReload()
    }

    /// ⌘Z / ⇧⌘T right after a Peek closed (nothing else undoable happened since): it opens again.
    func reopenClosedPeek() -> Bool {
        guard let r = recentlyClosedPeek, let url = r.url, r.undoCount == store.undoStack.count,
              Date().timeIntervalSince(r.at) < 120, peek == nil,
              let opener = shownTabID.flatMap({ engineTab(for: $0) }) else { return false }
        recentlyClosedPeek = nil
        openPeek(url, from: opener)
        return true
    }

    func layoutPeek() { peek?.view.layoutIn(page: card.frame) }
}
