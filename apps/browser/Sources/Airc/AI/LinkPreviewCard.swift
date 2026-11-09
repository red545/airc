// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// 5-second link previews (Arc Max, docs/user/ai.md): hold ⇧ over a link, or press and hold it, and a card under the
/// link shows the page it goes to: its title, a two- or three-sentence summary and its key points.
///
/// - The page script's "linkpreview" part (installed only while Settings → AI → "Link previews" is on and the model can
///   run) watches the top frame's links: ⇧ held over one (the pointer arriving with ⇧ down, or ⇧ pressed over it), or
///   a press held 0.5 s without moving. It reacts only to the person's own events (`isTrusted`), and the app checks
///   that ⇧ or the mouse button really is down and the pointer is over the page, so a page can't make Airc load
///   anything by itself.
/// - The page behind the link is read in the background in the same profile (HiddenPageReader) and summarized on this
///   Mac (AircKit's LinkPreviews: one load per page, kept for the session).
/// - Private windows: never (their pages aren't in a main window, and the check refuses them anyway). A site in
///   Settings → AI's "never" list gets no previews of its links, and none from its pages.
/// - A long press that showed a card doesn't also open the link when the button comes up.
/// - A card belongs to one page: its profile, its tab and the document the link was in. It goes when that page leaves
///   the screen (another tab, Space or split shown, the tab closed, the window gone) or navigates, when its profile is
///   cleared, and when its link is left; going stops the preview's load and model call. Nothing arrives late in it.
@MainActor
final class LinkPreviewFeature {
    static let shared = LinkPreviewFeature()
    /// The hold before a press counts as a long press (the page script's timer).
    static let pressDelay = 0.5
    /// How much of a page is read for its preview.
    static let readCap = 60_000

    /// Whether ⇧ or the main mouse button is down now, and where the pointer is (screen points). Scripted checks
    /// stand in for the person here (they can't post real input).
    static var input: () -> (shift: Bool, button: Bool, mouse: NSPoint) = {
        (NSEvent.modifierFlags.contains(.shift), NSEvent.pressedMouseButtons & 1 != 0, NSEvent.mouseLocation)
    }

    private(set) var installed = false
    private(set) var card: LinkPreviewCardView?
    private weak var cardController: WindowController?
    private weak var cardTab: EngineTab?
    private var shownURL: URL?
    private var shownProfile = ""
    /// The page script's token for the document the link was in (a new one per page load).
    private var shownDocument = ""
    private var hideWork: DispatchWorkItem?
    /// While a card shows: a look every quarter second that its page is still the one on screen.
    private var watch: Timer?
    /// Why the last request didn't show a card (the scripted check reads it).
    private(set) var lastRefusal: String?
    #if AIRC_TESTING
    /// Scripted runs dispatch the page's events themselves: the part takes synthetic ones too.
    static var trustSynthetic = false
    /// The scripted check: the page the card belongs to.
    var shownTab: EngineTab? { cardTab }
    /// The scripted check: the last "won't be previewed" toast shown.
    var lastToast: String?
    #endif

    // MARK: The page-script part

    /// On while the setting is on and the model can run; off removes the part and tells open pages to stop.
    func update(active: Bool) {
        guard active != installed, let scripts = PageScripts.shared else { return }
        installed = active
        let tabs = Self.mainWindowPages()
        if active {
            scripts.set("linkpreview", source: Self.source) { [weak self] tab, m in self?.received(tab, m) }
            scripts.pushNow()
            // Open pages get it now, without a reload.
            for tab in tabs { scripts.installNow("linkpreview", in: tab) }
        } else {
            scripts.remove("linkpreview") { _, _ in }
            scripts.pushNow()
            for tab in tabs { scripts.callPage(tab, part: "linkpreview", kind: "enabled", json: "false") }
            hide(animated: false)
        }
    }

    static func mainWindowPages() -> [EngineTab] {
        var seen = Set<ObjectIdentifier>()
        return ((NSApp.delegate as? AppDelegate)?.controllers ?? []).flatMap { Array($0.pages.values) }
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func received(_ tab: EngineTab, _ m: EnginePageMessage) {
        guard m.isMainFrame else { return }
        let body = (try? JSONSerialization.jsonObject(with: Data(m.json.utf8))) as? [String: Any] ?? [:]
        switch m.kind {
        case "hover", "press":
            request(tab, m, body, press: m.kind == "press")
        case "leave":
            guard cardTab === tab else { return }
            scheduleHide(after: 0.35)
        case "scroll", "doc":
            if cardTab === tab { hide() }
        default:
            break
        }
    }

    private func refuse(_ why: String) {
        lastRefusal = why
    }

    private func request(_ tab: EngineTab, _ m: EnginePageMessage, _ body: [String: Any], press: Bool) {
        guard let app = NSApp.delegate as? AppDelegate, let href = body["h"] as? String, let target = URL(string: href) else { return }
        // Main windows only: a private window's pages (and Little Arc's) are never in `controller(owning:)`.
        guard let c = app.controller(owning: tab), let tabID = c.tabID(for: tab), c.isVisiblePage(tabID) else {
            return refuse("not a page of a main window")
        }
        let ai = AIFeatures.shared
        let source = tab.url
        if let r = LinkPreviewPolicy.refusal(source: source, target: target, isPrivate: false,
                                             enabled: app.settings.values.linkPreviews, available: ai.canPreviewLinks,
                                             never: app.settings.values.linkPreviewNever) {
            return refuse("\(r)")
        }
        // The person really holds ⇧ (or the button), over this page: a page's own events can't ask for a load.
        let input = Self.input()
        guard press ? input.button : input.shift else { return refuse(press ? "the button isn't down" : "⇧ isn't down") }
        let view = tab.view
        if view.window === c.window, view.bounds.width > 0 {
            let onScreen = c.window.convertToScreen(view.convert(view.bounds, to: nil))
            guard onScreen.insetBy(dx: -4, dy: -4).contains(input.mouse) else { return refuse("the pointer isn't over the page") }
        }
        guard let profileID = app.profiles.profileID(for: tab.profile) else { return refuse("no profile") }
        lastRefusal = nil
        if press, let token = body["t"] as? String {
            _ = PageScripts.shared?.callDocument(tab, frame: m.frame, origin: m.origin, part: "linkpreview", kind: "armed", json: token)
        }
        let anchor = Self.anchorRect(body, in: tab, controller: c)
        show(target, profileID: profileID, from: tab, document: body["t"] as? String ?? "", in: c, anchor: anchor)
    }

    /// The link's box in the window's root view: the page's viewport coordinates (CSS pixels) scaled to the page view.
    static func anchorRect(_ body: [String: Any], in tab: EngineTab, controller c: WindowController) -> NSRect {
        let r = (body["r"] as? [NSNumber])?.map(\.doubleValue) ?? []
        let width = (body["w"] as? NSNumber)?.doubleValue ?? 0
        var page = c.card.frame
        let view = tab.view
        if view.window === c.window, view.bounds.width > 0 { page = view.convert(view.bounds, to: c.root) }
        guard r.count == 4, width > 0 else { return NSRect(x: page.midX, y: page.midY, width: 1, height: 1) }
        let scale = page.width / width
        // The root view is flipped like the page: y grows downwards.
        return NSRect(x: page.minX + r[0] * scale, y: page.minY + r[1] * scale, width: max(1, r[2] * scale), height: max(1, r[3] * scale))
    }

    // MARK: The card

    func show(_ url: URL, profileID: String, from tab: EngineTab, document: String, in c: WindowController, anchor: NSRect) {
        hideWork?.cancel()
        // The card already up is moved only when it's this very link's: the same address, profile, tab and document.
        if let shown = shownURL, LinkPreviewPolicy.key(shown) == LinkPreviewPolicy.key(url), shownProfile == profileID,
           cardTab === tab, shownDocument == document, cardController === c, card != nil {
            return place(anchor: anchor, in: c)
        }
        hide(animated: false)
        let card = LinkPreviewCardView(palette: c.currentPalette)
        card.apply(.loading, url: url)
        card.onHover = { [weak self] inside in
            if inside { self?.hideWork?.cancel() } else { self?.scheduleHide(after: 0.3) }
        }
        card.onOpen = { [weak self, weak c] in
            self?.hide()
            c?.navigate(to: url, newTab: true)
        }
        card.onNever = { [weak self] site in self?.never(site) }
        self.card = card
        cardController = c
        cardTab = tab
        shownURL = url
        shownProfile = profileID
        shownDocument = document
        c.root.addSubview(card, positioned: .below, relativeTo: c.toast)
        place(anchor: anchor, in: c)
        card.present()
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { _ = LinkPreviewFeature.shared.validate() }
        }
        AIFeatures.shared.recordUse(.aiLinkPreview(.used))
        AIFeatures.shared.links.preview(url, profileID: profileID) { [weak self, weak card] state in
            // Only into this card, while its page is still the one on screen (a late answer for another page is dropped).
            guard let self, let card, self.card === card, self.validate() else { return }
            card.apply(state, url: url)
            if let c = self.cardController { self.place(anchor: card.anchor, in: c) }
        }
    }

    /// Whether the card's page is still on screen as it was: its window there, its tab shown (alone or in the split),
    /// in the same profile. If not, the card goes. True while it may stay (or when there's no card).
    @discardableResult
    func validate() -> Bool {
        guard card != nil else { return true }
        guard let c = cardController, let tab = cardTab, !tab.isClosed, c.window.isVisible, let id = c.tabID(for: tab),
              c.isVisiblePage(id), (NSApp.delegate as? AppDelegate)?.profiles.profileID(for: tab.profile) == shownProfile else {
            hide(animated: false)
            return false
        }
        return true
    }

    /// A page went out of sight in a window (TabUnloading's pageVisibilityChanged): the card over it goes now.
    func pageHidden(_ tabID: String?, in c: WindowController) {
        guard card != nil, cardController === c else { return }
        if let tabID, let tab = cardTab, c.tabID(for: tab) == tabID { return hide(animated: false) }
        validate()
    }

    /// A profile's data cleared or the profile deleted: its card goes (its previews are forgotten by AIFeatures).
    func forget(profileID: String) {
        if card != nil, shownProfile == profileID { hide(animated: false) }
    }

    /// Under the link (above it when there's no room below), inside the page card. The root view is flipped.
    private func place(anchor: NSRect, in c: WindowController) {
        guard let card else { return }
        card.anchor = anchor
        let size = card.fittingSize(width: LinkPreviewCardView.width)
        let m = LinkPreviewCardView.margin, gap: CGFloat = 6
        let bounds = c.card.frame.insetBy(dx: 8, dy: 8)
        let x = min(max(anchor.minX - m, bounds.minX - m), bounds.maxX - size.width + m)
        let height = size.height - 2 * m
        var top = anchor.maxY + gap
        if top + height > bounds.maxY { top = max(bounds.minY, anchor.minY - gap - height) }
        card.frame = NSRect(x: x, y: top - m, width: size.width, height: size.height)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.card?.isHovered != true else { return }
            self.hide()
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// The card goes; its preview's load and model call stop if it wasn't finished.
    func hide(animated: Bool = true) {
        hideWork?.cancel()
        hideWork = nil
        watch?.invalidate()
        watch = nil
        if let url = shownURL { AIFeatures.shared.links.stopUpdates(url, profileID: shownProfile) }
        shownURL = nil
        shownDocument = ""
        cardTab = nil
        cardController = nil
        guard let card else { return }
        self.card = nil
        guard animated else { return card.removeFromSuperview() }
        card.layer?.fade(from: 1, to: 0, duration: 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { card.removeFromSuperview() }
    }

    /// The card's "Never preview <site>": the site goes into Settings → AI's list (its links and its pages).
    private func never(_ site: String) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        if !app.settings.values.linkPreviewNever.contains(site) { app.settings.values.linkPreviewNever.append(site) }
        // The card's window, before hiding lets go of it.
        let c = cardController
        hide()
        c?.showToast("Links to \(site) won't be previewed")
        #if AIRC_TESTING
        lastToast = c == nil ? nil : "Links to \(site) won't be previewed"
        #endif
    }

    /// The page script: links' hover with ⇧ and long presses, in the top frame, from the person's own events.
    static var source: String {
        var trust = "false"
        #if AIRC_TESTING
        if trustSynthetic { trust = "true" }
        #endif
        return """
        function (post) {
          var TRUST = \(trust);
          try { if (window.top !== window) return; } catch (e) { return; }
          var on = true, over = null, shown = null, pressed = null, armed = null, timer = 0, at = null;
          var token = Math.random().toString(36).slice(2) + Date.now().toString(36);
          function link(t) {
            while (t && t.nodeType !== 1) t = t.parentNode;
            return t && t.closest ? t.closest('a[href]') : null;
          }
          function ok(e) { return on && (e.isTrusted || TRUST); }
          function web(a) { var h = a && a.href; return typeof h === 'string' && /^https?:/i.test(h) ? h : null; }
          function send(kind, a) {
            var h = web(a);
            if (!h) return;
            var r = a.getBoundingClientRect();
            post(kind, JSON.stringify({ h: h, r: [r.left, r.top, r.width, r.height], w: innerWidth, v: innerHeight, t: token }));
          }
          function leave() { if (shown) { shown = null; post('leave', '{}'); } }
          addEventListener('mouseover', function (e) {
            if (!ok(e)) return;
            var a = link(e.target);
            if (a === over) return;
            if (shown && shown !== a) leave();
            over = a;
            if (a && e.shiftKey && web(a)) { shown = a; send('hover', a); }
          }, true);
          addEventListener('mouseout', function (e) {
            if (!ok(e) || !over) return;
            var to = link(e.relatedTarget);
            if (to === over) return;
            over = null;
            leave();
          }, true);
          addEventListener('keydown', function (e) {
            if (!ok(e) || e.key !== 'Shift' || e.repeat || !over || shown === over || !web(over)) return;
            shown = over;
            send('hover', over);
          }, true);
          function stop() { if (timer) { clearTimeout(timer); timer = 0; } }
          addEventListener('pointerdown', function (e) {
            stop();
            armed = null;
            if (!ok(e) || e.button !== 0 || e.shiftKey || e.metaKey || e.ctrlKey || e.altKey) return;
            var a = link(e.target);
            if (!web(a)) return;
            at = [e.clientX, e.clientY];
            timer = setTimeout(function () { timer = 0; pressed = a; over = a; shown = a; send('press', a); }, \(Int(pressDelay * 1000)));
          }, true);
          addEventListener('pointermove', function (e) {
            if (timer && at && Math.abs(e.clientX - at[0]) + Math.abs(e.clientY - at[1]) > 8) stop();
          }, true);
          addEventListener('pointerup', stop, true);
          addEventListener('pointercancel', stop, true);
          addEventListener('dragstart', stop, true);
          // The click that ends a long press that showed a card doesn't open the link.
          addEventListener('click', function (e) {
            var a = armed;
            armed = null;
            if (a && link(e.target) === a) { e.preventDefault(); e.stopImmediatePropagation(); }
          }, true);
          addEventListener('scroll', function () { if (shown) { shown = null; post('scroll', '{}'); } }, { capture: true, passive: true });
          addEventListener('pagehide', function () { post('doc', '{}'); });
          return function (kind, json) {
            if (kind === 'armed' && json === token) armed = pressed;
            else if (kind === 'enabled') { on = json === 'true'; if (!on) { stop(); shown = null; armed = null; } }
          };
        }
        """
    }

    // MARK: Hidden loads

    /// Reads a page in the background in a profile (LinkPreviews' fetch). Cancelled (the preview no longer wanted), its
    /// page leaves the queue, or closes if it's loading.
    @MainActor static func fetch(_ url: URL, profileID: String) async -> PageText? {
        guard let app = NSApp.delegate as? AppDelegate, let profile = app.profiles.engineProfile(for: profileID) else { return nil }
        let read = PendingRead()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                read.id = HiddenPageReader.shared.read(url, profile: profile, profileID: profileID, cap: readCap) { c.resume(returning: $0) }
            }
        } onCancel: {
            DispatchQueue.main.async { if let id = read.id { HiddenPageReader.shared.cancel(id) } }
        }
    }

    /// The hidden read a fetch waits for (set on the main thread before a cancellation can reach it there).
    private final class PendingRead: @unchecked Sendable { var id: Int? }
}

extension WindowController {
    /// TabUnloading's pageVisibilityChanged: a page here went out of sight; a preview card over it goes.
    func linkPreviewPageHidden(_ tabID: String?) { MainActor.assumeIsolated { LinkPreviewFeature.shared.pageHidden(tabID, in: self) } }
    /// MultiWindow's noteShown, on every way a tab is shown (a Space shown for the first time too, whose page comes a
    /// moment later): a card whose page isn't the one shown any more goes.
    func linkPreviewShownChanged() { MainActor.assumeIsolated { LinkPreviewFeature.shared.pageHidden(nil, in: self) } }
}

extension WindowController {
    /// The tab is on screen in this window: the one shown, or a pane of the split shown.
    func isVisiblePage(_ tabID: String) -> Bool {
        if shownTabID == tabID { return true }
        guard shownSplitID != nil else { return false }
        return splitContainer.pane(for: tabID) != nil
    }
}

/// The preview card: the page's title and site, the summary (or soft placeholder lines while it's made), its key
/// points, and Open and Never. Layers on the Space's surface at popover elevation, like the tab preview card; the view
/// is larger than the card by the shadow's reach and hit-tests only the card.
final class LinkPreviewCardView: NSView {
    static let width: CGFloat = 360
    static let margin: CGFloat = 20
    static let inset: CGFloat = 14

    var onHover: ((Bool) -> Void)?
    var onOpen: (() -> Void)?
    var onNever: ((String) -> Void)?
    /// The link's box it hangs from (root view coordinates).
    var anchor: NSRect = .zero
    private(set) var isHovered = false
    private(set) var state: LinkPreviews.State = .loading

    private let plate = CALayer()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let hostLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var pointLabels: [NSTextField] = []
    private let footer = NSTextField(labelWithString: "Summarized on this Mac")
    let openButton = GlyphButton(symbol: "arrow.up.right.square", size: 12)
    let neverButton = GlyphButton(symbol: "ellipsis", size: 12)
    private var placeholders: [CALayer] = []
    private let palette: Palette
    private var site = ""

    init(palette: Palette) {
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
        let t = palette.resolved
        plate.cornerRadius = AircRadius.popover
        plate.cornerCurve = .continuous
        plate.backgroundColor = t.surface.nsColor.cgColor
        plate.borderColor = t.surfaceBorder.nsColor.cgColor
        plate.borderWidth = 0.5
        plate.applyAircShadow(.popover)
        layer?.addSublayer(plate)
        titleLabel.font = AircFont.row.weight(.semibold).appFont
        titleLabel.textColor = t.surfaceText.nsColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.cell?.truncatesLastVisibleLine = true
        hostLabel.font = AircFont.caption.appFont
        hostLabel.textColor = t.surfaceTextSecondary.nsColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.font = AircFont.body.appFont
        summaryLabel.textColor = t.surfaceText.nsColor
        summaryLabel.maximumNumberOfLines = 7
        summaryLabel.cell?.truncatesLastVisibleLine = true
        footer.font = AircFont.caption.appFont
        footer.textColor = t.surfaceTextSecondary.nsColor.withAlphaComponent(0.8)
        for v in [titleLabel, hostLabel, summaryLabel, footer] as [NSTextField] {
            v.isSelectable = false
            v.drawsBackground = false
            v.isBezeled = false
            addSubview(v)
        }
        for b in [openButton, neverButton] {
            b.tint = t.surfaceTextSecondary.nsColor
            b.hoverFill = t.surfaceHover.nsColor
            b.plateRadius = AircRadius.control
            addSubview(b)
        }
        openButton.toolTip = "Open in a New Tab"
        openButton.action = { [weak self] in self?.onOpen?() }
        neverButton.toolTip = "More"
        neverButton.action = { [weak self] in self?.showMenu() }
        for _ in 0..<3 {
            let l = CALayer()
            l.cornerRadius = 4
            l.backgroundColor = t.surfaceTextSecondary.nsColor.withAlphaComponent(0.14).cgColor
            layer?.addSublayer(l)
            placeholders.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var cardRect: NSRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, cardRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }

    /// A click on the card (not its buttons) opens the page.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if cardRect.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { isHovered = false; onHover?(false) }

    func apply(_ s: LinkPreviews.State, url: URL) {
        state = s
        site = LinkPreviewPolicy.site(of: url) ?? (url.host ?? "")
        hostLabel.stringValue = URLRules.displayHost(url.absoluteString)
        titleLabel.stringValue = s.title ?? URLRules.displayHost(url.absoluteString)
        for l in pointLabels { l.removeFromSuperview() }
        pointLabels = []
        var waiting = false
        switch s {
        case .loading, .summarizing:
            summaryLabel.stringValue = ""
            waiting = true
        case .ready(_, let summary):
            summaryLabel.stringValue = summary.summary
            for p in summary.keyPoints {
                let l = NSTextField(wrappingLabelWithString: "•  " + p)
                l.font = AircFont.callout.appFont
                l.textColor = palette.resolved.surfaceText.nsColor.withAlphaComponent(0.86)
                l.maximumNumberOfLines = 2
                l.cell?.truncatesLastVisibleLine = true
                l.isSelectable = false
                addSubview(l)
                pointLabels.append(l)
            }
        case .unavailable(_, let why):
            switch why {
            case .tooLittleText: summaryLabel.stringValue = "There isn't enough text on this page to summarize."
            case .loadFailed: summaryLabel.stringValue = "This page couldn't be loaded for a preview."
            case .declined: summaryLabel.stringValue = "Apple Intelligence couldn't summarize this page."
            case .timedOut: summaryLabel.stringValue = "This page took too long to summarize."
            case .failed: summaryLabel.stringValue = "No preview for this page."
            }
        }
        var ready = false
        if case .ready = s { ready = true }
        summaryLabel.textColor = s.isFinished && !ready ? palette.resolved.surfaceTextSecondary.nsColor : palette.resolved.surfaceText.nsColor
        placeholders.forEach { $0.isHidden = !waiting }
        if waiting { shimmer() } else { placeholders.forEach { $0.removeAllAnimations() } }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// The card's size for a width (the shadow's room included).
    func fittingSize(width: CGFloat) -> NSSize {
        NSSize(width: width + 2 * Self.margin, height: contentHeight(width: width) + 2 * Self.margin)
    }

    private func textHeight(_ f: NSTextField, _ w: CGFloat) -> CGFloat {
        guard !f.stringValue.isEmpty else { return 0 }
        f.preferredMaxLayoutWidth = w
        return ceil(f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10_000)).height ?? 0)
    }

    private func contentHeight(width: CGFloat) -> CGFloat {
        let w = width - 2 * Self.inset
        var h = Self.inset + textHeight(titleLabel, w - 52) + 2 + 14 + 10
        if placeholders.first?.isHidden == false { h += 3 * 14 + 2 * 7 } else { h += textHeight(summaryLabel, w) }
        for p in pointLabels { h += 6 + textHeight(p, w) }
        h += 12 + 16 + Self.inset - 2
        return h
    }

    override func layout() {
        super.layout()
        let card = cardRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = card
        plate.shadowPath = CGPath(roundedRect: plate.bounds, cornerWidth: AircRadius.popover, cornerHeight: AircRadius.popover, transform: nil)
        let x = card.minX + Self.inset, w = card.width - 2 * Self.inset
        var y = card.minY + Self.inset
        let th = textHeight(titleLabel, w - 52)
        titleLabel.frame = NSRect(x: x - 2, y: y, width: w - 52, height: th)
        openButton.frame = NSRect(x: card.maxX - Self.inset - 24 - 26, y: y - 3, width: 24, height: 24)
        neverButton.frame = NSRect(x: card.maxX - Self.inset - 24, y: y - 3, width: 24, height: 24)
        y += th + 2
        hostLabel.frame = NSRect(x: x - 2, y: y, width: w, height: 14)
        y += 14 + 10
        if placeholders.first?.isHidden == false {
            for (i, l) in placeholders.enumerated() {
                l.frame = NSRect(x: x, y: y + 2, width: i == 2 ? w * 0.62 : w, height: 10)
                y += 14 + (i < 2 ? 7 : 0)
            }
            summaryLabel.frame = .zero
        } else {
            let sh = textHeight(summaryLabel, w)
            summaryLabel.frame = NSRect(x: x - 2, y: y, width: w + 4, height: sh)
            y += sh
        }
        for p in pointLabels {
            y += 6
            let ph = textHeight(p, w)
            p.frame = NSRect(x: x - 2, y: y, width: w + 4, height: ph)
            y += ph
        }
        y += 12
        footer.frame = NSRect(x: x - 2, y: y, width: w, height: 16)
        CATransaction.commit()
    }

    private func shimmer() {
        for (i, l) in placeholders.enumerated() where l.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.45
            a.duration = 0.9
            a.beginTime = CACurrentMediaTime() + Double(i) * 0.12
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            l.add(a, forKey: "pulse")
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open in a New Tab", action: #selector(menuOpen), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let never = NSMenuItem(title: "Never Preview Links on \(site)", action: #selector(menuNever), keyEquivalent: "")
        never.target = self
        menu.addItem(never)
        menu.popUp(positioning: nil, at: NSPoint(x: neverButton.frame.minX, y: neverButton.frame.maxY + 4), in: self)
    }

    @objc private func menuOpen() { onOpen?() }
    @objc func menuNever() { onNever?(site) }

    func present() {
        guard let layer else { return }
        layer.fade(from: 0, to: 1, duration: 0.14)
        let curve = AircCurve.dialog
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.97
        grow.toValue = 1
        grow.duration = curve.duration
        grow.timingFunction = curve.timingFunction
        plate.add(grow, forKey: "grow")
    }
}
