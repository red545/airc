// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import WebKit

/// H03 (Arc's "Share" in its tab menus and its main menu): the system's share menu (Messages, Mail, AirDrop, Notes…) for
/// exactly the links in question: a row's page, the selected rows', the page on screen or its Peek. The links lose
/// their trackers first, as Copy Link's do (LinkCopyPolicy); nothing else goes with them: no titles, no page content,
/// so a private window's share leaves nothing behind but what the person sent.
final class SelectionShare: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    let urls: [URL]
    let picker: NSSharingServicePicker
    /// A share in flight keeps itself (the picker's delegate is weak) until a service was chosen or the menu went.
    private static var showing: Set<SelectionShare> = []

    init?(_ links: [String]) {
        let urls = links.compactMap { URL(string: LinkCopyPolicy.clean($0)) }.filter { ["http", "https", "file"].contains($0.scheme ?? "") }
        guard !urls.isEmpty else { return nil }
        self.urls = urls
        picker = NSSharingServicePicker(items: urls)
        super.init()
        picker.delegate = self
    }

    /// Arc's "Share ›": the system's share item, its submenu listing the services for these links.
    func menuItem() -> NSMenuItem {
        let item = picker.standardShareMenuItem
        item.title = "Share"
        objc_setAssociatedObject(item, &Self.ownerKey, self, .OBJC_ASSOCIATION_RETAIN)
        return item
    }

    /// The share item a menu built by `menuItem()` carries.
    static func of(_ item: NSMenuItem) -> SelectionShare? { objc_getAssociatedObject(item, &ownerKey) as? SelectionShare }
    private static var ownerKey: UInt8 = 0

    /// The picker beside `rect` (the main menu's and the Command Bar's Share…).
    func show(relativeTo rect: NSRect, of view: NSView, edge: NSRectEdge) {
        Self.showing.insert(self)
        picker.show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    func sharingServicePicker(_ p: NSSharingServicePicker, sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        #if AIRC_TESTING
        if let t = Self.testService { return proposed + [t] }
        #endif
        return proposed
    }

    func sharingServicePicker(_ p: NSSharingServicePicker, delegateFor service: NSSharingService) -> NSSharingServiceDelegate? { self }

    func sharingServicePicker(_ p: NSSharingServicePicker, didChoose service: NSSharingService?) {
        DispatchQueue.main.async { Self.showing.remove(self) }
    }

    func sharingService(_ s: NSSharingService, willShareItems items: [Any]) {
        #if AIRC_TESTING
        Self.testShared?(s.title, items)
        #endif
    }

    #if AIRC_TESTING
    /// The P01 check's own service (it opens nothing): offered after the system's, and told what it shares.
    static var testService: NSSharingService?
    static var testShared: ((String, [Any]) -> Void)?

    /// Runs `service` with this share's links, as choosing it in the menu does (the system's sharing path, with this
    /// object as the service's delegate).
    func perform(_ service: NSSharingService) {
        service.delegate = self
        service.perform(withItems: urls)
    }
    #endif
}

extension WindowController {
    /// The address a tab's row stands for: its page's, else the one stored.
    func linkURL(ofTab id: String) -> String? {
        guard let t = store.tab(id) else { return nil }
        return engineTab(for: id)?.url?.absoluteString ?? t.url
    }

    /// The title a link takes: its page's, else the row's.
    func linkTitle(ofTab id: String) -> String {
        let page = engineTab(for: id)?.title ?? ""
        return page.isEmpty ? store.tab(id)?.displayTitle ?? "" : page
    }

    /// The links a multi-selection stands for, in order (Copy N Links' list).
    func selectionLinks(_ ids: [String]) -> [String] {
        store.links(of: selectionSources(ids)) { [weak self] t in self?.engineTab(for: t.id)?.url?.absoluteString }
    }

    /// A selection's Markdown (AircKit's linksMarkdown): its pages' own titles and addresses where they're loaded.
    func selectionMarkdown(_ ids: [String]) -> String {
        store.linksMarkdown(of: selectionSources(ids), current: { [weak self] t in
            guard let self, let page = self.engineTab(for: t.id), let u = page.url?.absoluteString else { return nil }
            return (u, page.title)
        }, clean: LinkCopyPolicy.clean)
    }

    // MARK: Hooks for the menus other files build

    /// A multi-selection's menu (SelectionActions.selectionMenu), after "Copy N Links": ⌥ turns that into "Copy N
    /// Links as Markdown", and "Share ›" offers exactly the selected rows' links.
    func addSelectionLinkItems(to m: NSMenu, ids: [String]) {
        let n = selectionSources(ids).count, links = selectionLinks(ids)
        let md = m.add("Copy \(n) Links as Markdown") { [weak self] in
            guard let self else { return }
            self.writeLinks(self.selectionMarkdown(ids), toast: links.count == 1 ? "Copied Link as Markdown" : "Copied Links as Markdown")
        }
        md.isAlternate = true
        md.keyEquivalentModifierMask = .option
        md.isEnabled = !links.isEmpty
        if let share = SelectionShare(links) { m.addItem(share.menuItem()) }
    }

    /// A split pane's part of a split menu (SplitActions, ItemSplitActions), after its "Copy Link": ⌥ "Copy Link as
    /// Markdown", and "Share ›" for that pane's page.
    func addPaneLinkItems(to m: NSMenu, tabID: String) {
        addLinkItems(to: m, tabID: tabID, share: true)
    }

    /// ⌥-alternate "Copy Link as Markdown" for the "Copy Link" just added, then "Share ›" (tab menus, panes).
    func addLinkItems(to m: NSMenu, tabID: String, share: Bool) {
        let md = m.add("Copy Link as Markdown") { [weak self] in self?.copyLinkMarkdown(of: tabID) }
        md.isAlternate = true
        md.keyEquivalentModifierMask = .option
        if share, let s = SelectionShare([linkURL(ofTab: tabID)].compactMap { $0 }) { m.addItem(s.menuItem()) }
    }

    func copyLinkMarkdown(of tabID: String) {
        guard let u = linkURL(ofTab: tabID) else { return }
        writeLinks(URLRules.markdownLink(title: linkTitle(ofTab: tabID), url: LinkCopyPolicy.clean(u)), toast: "Copied Link as Markdown")
    }

    /// Writes copied links to the link pasteboard (the person's clipboard; a check's own in scripted runs). Any Quote
    /// still reading its selection is dropped: this copy is the newer one.
    func writeLinks(_ text: String, toast: String) {
        guard !text.isEmpty else { return NSSound.beep() }
        Self.quoteGate.cancel()
        Self.linkPasteboard.clearContents()
        Self.linkPasteboard.setString(text, forType: .string)
        showToast(toast)
    }

    // MARK: Share… (the main menu, the Command Bar)

    /// The links Share… takes: the selected rows while the sidebar has them, else the page on screen (its Peek first).
    var shareLinks: [String] {
        if let (_, ids) = sidebarSelection { return selectionLinks(ids) }
        guard let page = displayedLinkPage, let u = page.url?.absoluteString, !NoteURL.isNote(u) else { return [] }
        return [u]
    }

    /// Arc's Share: the system picker beside the address (the sidebar's header), or at the top of the page when the
    /// sidebar is hidden.
    func shareCurrent() {
        guard let share = SelectionShare(shareLinks) else { return NSSound.beep() }
        if !sidebarHidden, sidebar.header.window != nil, !sidebar.header.isHidden {
            share.show(relativeTo: sidebar.header.bounds, of: sidebar.header, edge: sidebarOnRight ? .minX : .maxX)
        } else {
            share.show(relativeTo: NSRect(x: card.bounds.midX - 1, y: card.bounds.maxY - 2, width: 2, height: 2), of: card, edge: .minY)
        }
    }
}

// MARK: A link straight to the copied text (C06)

/// Arc's offer after ⌘C on a page's selected text: "Share a link directly to this text instead?" with Arc's button
/// "Copy Quote Link", which copies the page's link to that text (a text fragment that scrolls to and highlights it). It
/// goes by itself after a few seconds; nothing is copied unless the person asks.
final class QuoteLinkOfferView: NSView {
    static let message = "Share a link directly to this text instead?"
    let label = NSTextField(labelWithString: QuoteLinkOfferView.message)
    let button = NSButton(title: QuoteLink.copyTitle, target: nil, action: nil)
    /// The link the button copies.
    private(set) var link = ""
    var onCopy: ((String) -> Void)?
    /// P01c: its right-click menu's "Disable Shared Quotes" (Arc's label for the switch).
    var onDisable: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.toast
        layer?.cornerCurve = .continuous
        layer?.apply(.toast)
        label.font = AircFont.body.weight(.medium).appFont
        button.isBordered = false
        button.font = AircFont.body.weight(.semibold).appFont
        button.target = self
        button.action = #selector(copyLink)
        addSubview(label)
        addSubview(button)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func copyLink() {
        hide()
        onCopy?(link)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.add("Disable Shared Quotes") { [weak self] in
            self?.hide()
            self?.onDisable?()
        }
        return m
    }

    func show(_ link: String, palette: Palette, in container: NSRect, duration: Double = 6) {
        self.link = link
        label.textColor = palette.panelText
        button.contentTintColor = palette.resolved.accentText.nsColor
        layer?.backgroundColor = palette.panelBackground.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = palette.panelBorder.cgColor
        label.sizeToFit()
        button.sizeToFit()
        let h = AircMetrics.Toast.height, gap = AircSpacing.m
        let w = AircSpacing.l + label.frame.width + gap + button.frame.width + AircSpacing.l
        frame = NSRect(x: container.midX - w / 2, y: container.minY + AircMetrics.Toast.topInset, width: w, height: h)
        label.frame.origin = NSPoint(x: AircSpacing.l, y: (h - label.frame.height) / 2)
        button.frame.origin = NSPoint(x: label.frame.maxX + gap, y: (h - button.frame.height) / 2)
        isHidden = false
        layer?.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard !isHidden else { return }
        layer?.fade(from: 1, to: 0, duration: AircCurve.toastOut.duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + AircCurve.toastOut.duration) { [weak self] in self?.isHidden = true }
    }
}

extension WindowController {
    /// Where a page's ⌘C goes: the person's clipboard (a check's own pasteboard in scripted runs).
    static var copyWatchPasteboard: NSPasteboard = .general

    /// The offer over this window's page, if it has been made.
    var quoteLinkOffer: QuoteLinkOfferView? { root.subviews.first { $0 is QuoteLinkOfferView } as? QuoteLinkOfferView }

    /// ⌘C went to the page (KeyMonitor): once the page has written the clipboard, Arc's offer, if what it copied is
    /// the page's selected text.
    func watchCopyForQuoteLink() {
        let board = Self.copyWatchPasteboard, before = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.offerQuoteLink(after: before, on: board) }
    }

    /// Offers the link when `board` has changed since `before` and holds the page's selection (whitespace aside).
    func offerQuoteLink(after before: Int, on board: NSPasteboard) {
        // P01c: Arc's Disable Shared Quotes turns the offer off.
        guard app?.settings.values.sharedQuotes != false, board.changeCount != before, let copied = board.string(forType: .string), let page = displayedLinkPage,
              let url = page.url?.absoluteString else { return }
        let changeCount = board.changeCount
        func words(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ") }
        page.evaluate(Self.selectionToWholeWordsScript) { [weak self, weak page] v in
            let pair = (v as? [Any])?.compactMap { $0 as? String } ?? []
            guard let self, let page, page === self.displayedLinkPage, board.changeCount == changeCount, pair.count == 2,
                  case let selection = pair[0], words(selection).count >= 3, words(selection) == words(copied),
                  QuoteLink.optOut(.init(url: url)) == nil, case let whole = pair[1].isEmpty ? selection : pair[1],
                  let link = LinkCopyPolicy.textFragmentURL(url, selection: whole) else { return }
            self.showQuoteLinkOffer(link) { [weak self, weak page] in
                guard let self, let page else { return }
                self.copyQuoteLink(page: page, url: url, selection: whole)
            }
        }
    }

    /// The page's selection, and the same text out to whole words: a text fragment only matches at word boundaries, so
    /// a selection that starts or ends inside a word ("…the ferries sto") would make a link that finds nothing. Chrome's
    /// Copy Link to Highlight does the same. The page's selection itself isn't changed.
    static let selectionToWholeWordsScript = """
        (function(){var s=window.getSelection();var t=String(s||'');if(!s||!s.rangeCount)return [t,t];
        var r=s.getRangeAt(0).cloneRange();var w=/[\\p{L}\\p{N}\\p{M}_'’]/u;
        var n=r.startContainer,o=r.startOffset;if(n.nodeType===3){while(o>0&&w.test(n.data[o-1]))o--;r.setStart(n,o);}
        n=r.endContainer;o=r.endOffset;if(n.nodeType===3){while(o<n.data.length&&w.test(n.data[o]))o++;r.setEnd(n,o);}
        return [t,String(r)];})()
        """

    /// `copy` runs on Copy Quote Link (the page's own quote copy, with its opt-outs); without one, `link` is copied as is.
    func showQuoteLinkOffer(_ link: String, copy: (() -> Void)? = nil) {
        let offer = quoteLinkOffer ?? {
            let v = QuoteLinkOfferView()
            root.addSubview(v, positioned: .below, relativeTo: toast)
            return v
        }()
        offer.onCopy = { [weak self] link in
            if let copy { return copy() }
            self?.writeQuoteLink(link, withQuote: true)
        }
        offer.onDisable = { [weak self] in self?.setSharedQuotes(false) }
        offer.show(link, palette: currentPalette, in: card.frame)
    }
}

// MARK: Arc's Share Quote, inside the address pill (C06; sidebarchrome 2026-11-20)

/// Arc's Share Quote ("Share Quote", decoded from Arc 1.171) while page text is selected: a chip that slides in at the
/// address pill's right end (owner 2026-11-20: inside the pill, so nothing below it moves: 0 px layout shift). The host
/// fades earlier to make room. A click copies the page's link to the selected text, the same whole-word text fragment as
/// the ⌘C offer, cleaned by the Super Copy policy (LinkCopyPolicy). It appears once a selection is made (after the
/// mouse-up or the key that made it, never during a drag) and goes when the selection does, when another page is on
/// screen, the sidebar hides, or Shared Quotes is turned off.
final class QuotePillView: NSView {
    static let title = "Share Quote"
    weak var controller: WindowController?
    let icon = NSImageView()
    let label = NSTextField(labelWithString: QuotePillView.title)
    /// The link a click copies (where the page takes quote links).
    private(set) var link = ""
    /// The page's address and the selection out to whole words, which the copy goes by.
    private var pageURL = "", selection = ""
    /// The page the link is for (the chip goes when another one is on screen).
    private weak var page: EngineTab?
    private var poll: Timer?
    /// Each new look at the selection; a slower, older answer is ignored.
    private var generation = 0
    private var hovered = false
    private var pressed = false
    /// Sliding out: still on screen, already gone as far as a new selection is concerned.
    private var leaving = false
    /// How often it appeared (a drag shows it once, after the mouse-up).
    private(set) var shows = 0
    /// The address field it sits in now (the current Space's).
    private(set) weak var field: URLFieldView?

    /// Inset from the pill's edges: the chip's corners stay concentric with the pill's (radius 12 − 4).
    static let inset: CGFloat = 4
    static var height: CGFloat { AircMetrics.Sidebar.urlFieldHeight - 2 * inset }
    /// The slide: in ≤ 150 ms (owner), out a little faster; a few points, with the fade.
    static let slideIn: CFTimeInterval = 0.14, slideOut: CFTimeInterval = 0.11, slideDistance: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.row - Self.inset
        layer?.cornerCurve = .continuous
        icon.image = NSImage(systemSymbolName: "quote.opening", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        label.font = AircFont.callout.weight(.medium).appFont
        label.lineBreakMode = .byClipping
        addSubview(icon)
        addSubview(label)
        isHidden = true
        toolTip = "Copy a link to the selected text"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.title)
        setAccessibilityHelp("Copies a link that opens this page at the selected text")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole chip takes the click (not its label or glyph), and never while it slides out.
    override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && !leaving && frame.contains(point) ? self : nil }
    override func accessibilityPerformPress() -> Bool { copyLink(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; paint() }
    override func mouseExited(with event: NSEvent) { hovered = false; paint() }

    override func mouseDown(with event: NSEvent) {
        if openContextMenuForControlClick(event) { return }
        pressed = true
        paint()
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { copyLink() } else { paint() }
    }

    /// Its right-click menu: Arc's switch, as on the ⌘C offer.
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.add("Disable Shared Quotes") { [weak self] in
            self?.hide()
            self?.controller?.setSharedQuotes(false)
        }
        return m
    }

    func copyLink() {
        guard !isHidden, !leaving, !link.isEmpty else { return }
        let (url, text, on) = (pageURL, selection, page)
        hide()
        guard let on else { return }
        controller?.copyQuoteLink(page: on, url: url, selection: text)
    }

    /// A raised chip in the pill, like a selected row (its fill and, where the theme has one, its soft shadow), so it
    /// reads in light, dark and every Space colour; hover brings the text up, a press takes the pressed fill.
    private func paint() {
        guard let c = controller else { return }
        let p = c.currentPalette
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (pressed ? p.pressed : hovered ? p.tileHover : p.selected).cgColor
        let shadow = p.resolved.selectedHasShadow && !pressed
        layer?.shadowOpacity = shadow ? 0.10 : 0
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.shadowColor = NSColor.black.cgColor
        CATransaction.commit()
        icon.contentTintColor = hovered ? p.textPrimary : p.glyph
        label.textColor = hovered || pressed ? p.textPrimary : p.textSecondary
    }

    /// The chip's width for its title: 9 pt · glyph · 4 pt · title · 10 pt.
    var preferredWidth: CGFloat {
        label.sizeToFit()
        return 9 + 11 + 4 + ceil(label.frame.width) + 10
    }

    /// The glyph alone, in a narrow sidebar.
    var compact = false { didSet { if compact != oldValue { label.isHidden = compact; needsLayout = true } } }

    /// Lays out the glyph and title (URLFieldView places the chip itself).
    override func layout() {
        super.layout()
        label.sizeToFit()
        let h = bounds.height, glyph: CGFloat = 11
        icon.frame = NSRect(x: compact ? ((bounds.width - glyph) / 2).rounded() : 9, y: ((h - glyph) / 2).rounded(), width: glyph, height: glyph)
        label.frame.origin = NSPoint(x: 9 + glyph + 4, y: ((h - label.frame.height) / 2).rounded())
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: layer?.cornerRadius ?? 8, cornerHeight: layer?.cornerRadius ?? 8, transform: nil)
    }

    /// Into the current Space's address field (a Space switch shows another page's field).
    func place() {
        guard let c = controller, let f = c.pageView(for: c.currentSpaceID)?.urlField else { return }
        if f !== field {
            field?.quoteChip = nil
            field = f
        }
        if superview !== f { f.addSubview(self) }
        f.quoteChip = self
    }

    /// The page's selection may have changed (a mouse-up or a key in the window): look again, and show the pill for a
    /// selection worth a link. `poll` looks only to take it away: it never shows the pill by itself.
    func refresh(poll fromPoll: Bool = false) {
        guard let c = controller else { return }
        generation += 1
        let asked = generation
        guard c.app?.settings.values.sharedQuotes != false, !c.sidebarHidden, !c.sidebar.isHidden, c.peek == nil,
              let id = c.shownTabID, !c.store.isNoteTab(id), let page = c.engineTab(for: id),
              let url = page.url?.absoluteString, url.hasPrefix("http://") || url.hasPrefix("https://"),
              QuoteLink.optOut(.init(url: url)) == nil, !fromPoll || page === self.page else { return hide() }
        page.evaluate(Self.selectionScript) { [weak self, weak page] v in
            guard let self, let page, asked == self.generation, page === c.shownTabID.flatMap(c.engineTab) else { return }
            let pair = (v as? [Any])?.compactMap { $0 as? String } ?? []
            func words(_ s: String) -> [Substring] { s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) }
            guard pair.count == 2, words(pair[0]).count >= 3, case let whole = pair[1].isEmpty ? pair[0] : pair[1],
                  let link = LinkCopyPolicy.textFragmentURL(url, selection: whole) else { return self.hide() }
            // The sidebar may have been resized meanwhile.
            if fromPoll { if link != self.link { self.hide() } else { self.place() }; return }
            self.pageURL = url
            self.selection = whole
            self.show(link, for: page)
        }
    }

    /// The page's selection out to whole words (`selectionToWholeWordsScript`); null while a field or an editor has the
    /// focus (a text fragment can't point into one).
    static let selectionScript = "(function(){var a=document.activeElement;"
        + "if(a&&(a.isContentEditable||/^(input|textarea|select)$/i.test(a.tagName)))return null;"
        + "var s=window.getSelection();if(!s||s.isCollapsed)return null;return \(WindowController.selectionToWholeWordsScript.trimmingCharacters(in: .whitespacesAndNewlines))})()"

    private func show(_ link: String, for page: EngineTab) {
        self.link = link
        self.page = page
        place()
        paint()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh(poll: true) }
        guard isHidden || leaving, let field, let layer else { return }
        let from = leaving ? layer.presentation() : nil
        if isHidden { shows += 1 }
        leaving = false
        isHidden = false
        // The field makes room at once (the host fades earlier, inside the pill); only the chip moves.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.chipShown = true
        field.layoutSubtreeIfNeeded()
        layer.opacity = 1
        CATransaction.commit()
        animate(layer, opacity: (Float(from?.opacity ?? 0), 1), dx: (from == nil ? Self.slideDistance : 0, 0), duration: Self.slideIn,
                curve: CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1))
    }

    func hide() {
        poll?.invalidate()
        poll = nil
        generation += 1
        pressed = false
        guard !isHidden, !leaving, let layer else { return }
        leaving = true
        hovered = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
        animate(layer, opacity: (1, 0), dx: (0, Self.slideDistance), duration: Self.slideOut, curve: CAMediaTimingFunction(name: .easeIn))
        let shown = shows
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideOut) { [weak self] in
            guard let self, self.shows == shown, self.leaving else { return }
            self.leaving = false
            self.isHidden = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer?.opacity = 1
            // The host has its room back once the chip is gone (never under the sliding chip).
            self.field?.chipShown = false
            self.field?.layoutSubtreeIfNeeded()
            CATransaction.commit()
        }
    }

    /// Opacity and a sideways slide in the render server (no layout pass; Reduce Motion: the fade alone).
    private func animate(_ layer: CALayer, opacity: (Float, Float), dx: (CGFloat, CGFloat), duration: CFTimeInterval,
                         curve: CAMediaTimingFunction) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.0
        fade.toValue = opacity.1
        var anims: [CAAnimation] = [fade]
        if !AircMotion.prefersReducedMotion, dx.0 != dx.1 {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = dx.0
            slide.toValue = dx.1
            anims.append(slide)
        }
        let g = CAAnimationGroup()
        g.animations = anims
        g.duration = duration
        g.timingFunction = curve
        layer.add(g, forKey: "quoteChip")
    }

    // MARK: Where selections change

    private static var monitor: Any?

    /// One monitor for the app: a mouse-up or a key-up in a browser window, once the page has taken it, makes that
    /// window's pill look at the selection. A drag selects with no mouse-up until it ends, so the pill never flickers.
    static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { event in
            guard let w = event.window, let c = (NSApp.delegate as? AppDelegate)?.controller(for: w), let pill = c.quotePill else { return event }
            if event.type == .leftMouseUp, !pill.isHidden, pill.bounds.contains(pill.convert(event.locationInWindow, from: nil)) { return event }
            // Once the page has had the event, and again a little later: an engine may update its selection after
            // the event reached it (a later answer replaces the first).
            for delay in [0.12, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak c, weak pill] in
                    guard let c, let pill, c.focusedPage != nil || !pill.isHidden else { return }
                    pill.refresh()
                }
            }
            return event
        }
    }
}

extension WindowController {
    private static let quoteChips = NSMapTable<WindowController, QuotePillView>.weakToStrongObjects()

    /// The Share Quote chip of this window (in the current Space's address pill while it shows).
    var quotePill: QuotePillView? { Self.quoteChips.object(forKey: self) }

    /// From the sidebar (SidebarView.connect): the chip, and the app's selection monitor.
    func installQuotePill() {
        guard quotePill == nil else { return }
        let pill = QuotePillView()
        pill.controller = self
        Self.quoteChips.setObject(pill, forKey: self)
        QuotePillView.installMonitor()
    }
}

// MARK: Copy Quote Link (C06)

extension WindowController {
    /// What is known about pages' quote opt-outs, by address without its fragment: their type and Document-Policy.
    private static var quotePageFacts: [String: (type: String, policy: String)] = [:]

    #if AIRC_TESTING
    /// The checks start each case from what the page says now.
    static func forgetQuotePageFacts() { quotePageFacts.removeAll() }
    /// The facts the last copy went by (the opt-out checks read why a page got a plain link).
    static var lastQuoteFacts: QuoteLink.Page?
    #endif

    /// Arc's toast after a quote copy: "Copied Link", and with a quote bubble and "With Quote" when the link goes to it.
    func showQuoteToast(withQuote: Bool) {
        toast.show(QuoteLink.copiedToast, palette: currentPalette, in: card.frame,
                   detail: withQuote ? QuoteLink.withQuote : nil, symbol: withQuote ? QuoteLink.symbol : nil)
    }

    /// Writes a quote copy's link to the link pasteboard, with Arc's toast.
    func writeQuoteLink(_ link: String, withQuote: Bool) {
        guard !link.isEmpty else { return NSSound.beep() }
        Self.quoteGate.cancel()
        Self.linkPasteboard.clearContents()
        Self.linkPasteboard.setString(link, forType: .string)
        showQuoteToast(withQuote: withQuote)
    }

    /// Arc's Copy Quote Link (the ⌘C offer, Share Quote, the page menu): the link to `selection` on `page`, or, where
    /// such a link can't work (QuoteLink.optOut: a PDF, a site that always opens at the top, a page that doesn't answer),
    /// the page's clean link. What the page is gets asked first; a newer copy, another page or a Peek meanwhile wins.
    func copyQuoteLink(page: EngineTab, url: String, selection: String) {
        let board = Self.linkPasteboard
        let ticket = Self.quoteGate.begin(quoteContext(), changeCount: board.changeCount)
        quotePageFacts(page, url: url) { [weak self] facts in
            #if AIRC_TESTING
            Self.lastQuoteFacts = facts
            #endif
            guard let self, Self.quoteGate.finish(ticket, now: self.quoteContext(), changeCount: board.changeCount),
                  let out = QuoteLink.copy(facts, selection: selection) else { return }
            board.clearContents()
            board.setString(out.link, forType: .string)
            self.showQuoteToast(withQuote: out.withQuote)
        }
    }

    /// The page's quote facts: its content type (a PDF) and its `Document-Policy` header, read with a HEAD request to
    /// the page's own address from the page (its cookies, its cache first). Once per address; a page that doesn't
    /// answer within 1.5 s is `unreadable` (not remembered).
    func quotePageFacts(_ page: EngineTab, url: String, _ done: @escaping (QuoteLink.Page) -> Void) {
        var facts = QuoteLink.Page(url: url)
        // Not a website, or a .pdf by its name: nothing to ask.
        guard QuoteLink.optOut(facts) == nil else { return done(facts) }
        let key = url.components(separatedBy: "#").first ?? url
        if let known = Self.quotePageFacts[key] {
            facts.contentType = known.type
            facts.documentPolicy = known.policy
            return done(facts)
        }
        var answered = false
        func finish(_ answer: [String]?) {
            guard !answered else { return }
            answered = true
            if let answer, answer.count == 2 {
                facts.contentType = answer[0].isEmpty ? nil : answer[0]
                facts.documentPolicy = answer[1]
                if Self.quotePageFacts.count > 200 { Self.quotePageFacts.removeAll() }
                Self.quotePageFacts[key] = (answer[0], answer[1])
            } else {
                facts.unreadable = true
            }
            done(facts)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(nil) }
        let body = Self.quoteFactsScript
        if let wk = page as? WebKitTab {
            // WebKit's evaluate doesn't wait for a promise; this does, in Airc's own script world.
            wk.webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .defaultClient) { result in
                finish((try? result.get()) as? [String])
            }
        } else {
            page.evaluate("(async function(){\(body)})()") { v in finish(v as? [String]) }
        }
    }

    /// An async function body: the document's type and its Document-Policy header ("" when it has none, or the request
    /// fails or takes over a second).
    static let quoteFactsScript = """
        const type = String(document.contentType || '');
        if (/pdf/i.test(type)) return [type, ''];
        let policy = '';
        try {
          const ctl = new AbortController();
          const timer = setTimeout(() => ctl.abort(), 1000);
          const r = await fetch(location.href.split('#')[0], {method: 'HEAD', cache: 'force-cache', credentials: 'include', signal: ctl.signal});
          clearTimeout(timer);
          policy = r.headers.get('document-policy') || '';
        } catch (e) {}
        return [type, policy];
        """

    /// The page menu's Copy Quote Link (QuoteLinkMenu): `tab`'s selection out to whole words.
    func copyQuoteLinkFromMenu(_ tab: EngineTab) {
        guard let url = tab.url?.absoluteString else { return NSSound.beep() }
        var asked = false
        func copy(_ selection: String) {
            guard !asked else { return }
            asked = true
            copyQuoteLink(page: tab, url: url, selection: selection)
        }
        // A page that runs no script (a PDF viewer): the page's link, after the facts' own wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copy("") }
        tab.evaluate(Self.selectionToWholeWordsScript) { v in
            let pair = (v as? [Any])?.compactMap { $0 as? String } ?? []
            copy(pair.count == 2 ? (pair[1].isEmpty ? pair[0] : pair[1]) : "")
        }
    }
}

/// C06: "Copy Quote Link" in a page's menu on selected text (not in a field), first after Copy.
enum QuoteLinkMenu {
    static let id = "quote.copy"

    /// Chromium's menu context has the selection; WebKit's says only whether its menu has Copy (`hasSelection`).
    static func items(_ context: [String: Any]) -> [[String: String]] {
        let text = (context["selection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard context["editable"] as? Bool != true, !text.isEmpty || context["hasSelection"] as? Bool == true else { return [] }
        return [["id": id, "title": QuoteLink.copyTitle]]
    }
}
