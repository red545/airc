// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

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

/// Arc's offer after ⌘C on a page's selected text: "Share a link directly to this text instead?" with a button that
/// copies the page's link to that text (a text fragment that scrolls to and highlights it). It goes by itself after a few
/// seconds; nothing is copied unless the person asks.
final class QuoteLinkOfferView: NSView {
    static let message = "Share a link directly to this text instead?"
    let label = NSTextField(labelWithString: QuoteLinkOfferView.message)
    let button = NSButton(title: "Copy Link", target: nil, action: nil)
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
        button.contentTintColor = palette.resolved.accent.nsColor
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
        page.evaluate("String(window.getSelection() || '')") { [weak self, weak page] v in
            guard let self, let page, page === self.displayedLinkPage, board.changeCount == changeCount,
                  let selection = v as? String, words(selection).count >= 3, words(selection) == words(copied),
                  let link = LinkCopyPolicy.textFragmentURL(url, selection: selection) else { return }
            self.showQuoteLinkOffer(link)
        }
    }

    func showQuoteLinkOffer(_ link: String) {
        let offer = quoteLinkOffer ?? {
            let v = QuoteLinkOfferView()
            root.addSubview(v, positioned: .below, relativeTo: toast)
            return v
        }()
        offer.onCopy = { [weak self] link in self?.writeLinks(link, toast: "Copied a link to this text") }
        offer.onDisable = { [weak self] in self?.setSharedQuotes(false) }
        offer.show(link, palette: currentPalette, in: card.frame)
    }
}
