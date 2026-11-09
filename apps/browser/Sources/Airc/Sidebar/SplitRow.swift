// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// SV-1: a split is one row in Today (Arc ref §5). The row's plate holds one segment per pane, in pane order, each with
/// its favicon and (where there's room) its title, split by a hairline. A press on a segment shows the split with that
/// pane focused; ✕ on a hovered segment closes that pane; the context menu has Separate All Tabs. While the split is on
/// screen the row is selected and the focused pane's title is the brighter one. A vertical split's segments are the
/// same, with a small stacked glyph after the last one.
///
/// SV-2: a pinned split's row is the same row in Pinned (indented in folders), built from its pane items, so it shows
/// without a loaded page. As on a pinned tab's row (SB-30, SB-31): an unloaded pane's favicon is at half strength; a
/// pane away from its saved URL shows " /" after its name and, on hover, a "Back to pinned URL" arrow for its favicon
/// that resets just that pane (⌘-click keeps the current page in a new Today tab); one ✕ (− while selected) closes the
/// whole split and keeps the row.
final class SplitRowView: SidebarRowView {
    /// The Today split this row is (nil for a pinned split's row).
    private(set) var split: Split?
    private(set) var tabs: [LiveTab] = []
    private(set) var entry: SidebarEntry?
    /// SV-2: the pinned split item this row is (nil for a Today split's row).
    private(set) var splitItem: Item?
    private(set) var depth = 0
    /// The pane with the keyboard while the split is on screen.
    private var focusedTabID: String?

    @MainActor private final class Segment {
        let favicon = FaviconView()
        let title = AircFadingLabel(style: AircFont.row)
        /// A pane in another profile than the row's Space (a cross-Space split) wears that profile's avatar.
        let badge = CALayer()
        var frame = NSRect.zero
        /// The pane's tab, "" while a pinned split's pane isn't loaded.
        var tabID = ""
        /// SV-2: the pane item of a pinned split.
        var paneID: String?
        var drifted = false
        init() {
            title.font = AircFont.row.appFont
            title.lineBreakMode = .byClipping
        }
    }

    /// What a segment shows.
    private struct Model {
        var tabID: String
        var paneID: String?
        var title: NSAttributedString
        var image: NSImage?
        var iconURL: String?
        var page: String
        var alpha: CGFloat
        var drifted: Bool
        var badge: Profile?
    }

    private var segments: [Segment] = []
    private var separators: [CALayer] = []
    private let stacked = CALayer()
    private var close: GlyphButton?
    private var axis: SplitAxis = .horizontal
    private var hoveredSegment: Int? { didSet { if hoveredSegment != oldValue { updateStyle(); needsLayout = true } } }
    /// SV-2: the drifted segment whose favicon is under the pointer (it shows the reset arrow).
    private var hoveredFavicon: Int? { didSet { if hoveredFavicon != oldValue { refresh() } } }
    /// A segment narrower than this shows only its icon.
    static let minTitled: CGFloat = 70

    override init(frame: NSRect) {
        super.init(frame: frame)
        stacked.actions = LayerImage.noActions
        stacked.contentsGravity = .center
        layer?.addSublayer(stacked)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: SidebarEntry, palette: Palette, selected: Bool, focusedTabID: String?) {
        guard case .split(let x, let tabs) = entry else { return }
        self.entry = entry
        self.split = x
        self.splitItem = nil
        self.depth = 0
        self.tabs = tabs
        self.palette = palette
        self.focusedTabID = selected ? focusedTabID : nil
        let home = controller?.store.space(x.spaceID)?.profileID
        let models = tabs.map { t -> Model in
            let page = controller?.engineTab(for: t.id)
            let text = page?.title.isEmpty == false ? page!.title : t.displayTitle
            let dim = selected && t.id != focusedTabID
            let color = dim ? palette.textSecondary : palette.textPrimary
            return Model(tabID: t.id, paneID: nil,
                         title: NSAttributedString(string: TextLimits.clip(text), attributes: [.foregroundColor: color, .font: AircFont.row.appFont]),
                         // A note's pane has no page (Notes/NoteSplit.swift): never dimmed as unloaded.
                         image: page?.favicon, iconURL: t.faviconURL, page: t.url, alpha: page == nil && !NoteURL.isNote(t.url) ? 0.5 : 1, drifted: false,
                         badge: t.profileID != home ? controller?.store.profile(t.profileID) : nil)
        }
        apply(models, axis: x.axis, palette: palette, selected: selected)
    }

    /// SV-2: a pinned split's row, from its pane items (loaded or not).
    func configure(splitItem item: Item, depth: Int, palette: Palette, selected: Bool, focusedTabID: String?) {
        guard let store = controller?.store else { return }
        let live = store.liveTab(forSplitItem: item.id)
        self.entry = .pinned(item, depth: depth, live)
        self.split = nil
        self.splitItem = item
        self.depth = depth
        self.palette = palette
        self.focusedTabID = selected ? focusedTabID : nil
        var shown: [LiveTab] = []
        let models = store.panes(ofSplitItem: item.id).map { pane -> Model in
            let t = store.liveTab(forItem: pane.id)
            if let t { shown.append(t) }
            let page = t.flatMap { controller?.engineTab(for: $0.id) }
            let drifted = t.map { tab in pane.savedURL.map { URLRules.isDrifted(saved: $0, current: tab.url) } ?? false } ?? false
            let dim = selected && t?.id != focusedTabID
            let s = NSMutableAttributedString(string: TextLimits.clip(pane.displayTitle),
                                              attributes: [.foregroundColor: dim ? palette.textSecondary : palette.textPrimary, .font: AircFont.row.appFont])
            if drifted { s.append(NSAttributedString(string: " /", attributes: [.foregroundColor: palette.textMuted, .font: AircFont.row.appFont])) }
            return Model(tabID: t?.id ?? "", paneID: pane.id, title: s, image: page?.favicon, iconURL: t?.faviconURL ?? pane.faviconURL,
                         page: t?.url ?? pane.savedURL ?? "", alpha: controller?.isPageUnloaded(t?.id) != false ? 0.5 : 1,
                         drifted: drifted, badge: nil)
        }
        tabs = shown
        apply(models, axis: item.splitLayout?.axis ?? .horizontal, palette: palette, selected: selected)
    }

    private func apply(_ models: [Model], axis: SplitAxis, palette: Palette, selected: Bool) {
        self.axis = axis
        while segments.count < models.count {
            let s = Segment()
            addSubview(s.favicon)
            addSubview(s.title)
            s.badge.actions = LayerImage.noActions
            s.badge.zPosition = 10
            layer?.addSublayer(s.badge)
            segments.append(s)
        }
        while segments.count > models.count {
            let s = segments.removeLast()
            s.favicon.removeFromSuperview()
            s.title.removeFromSuperview()
            s.badge.removeFromSuperlayer()
        }
        while separators.count < max(0, models.count - 1) {
            let l = CALayer()
            l.actions = LayerImage.noActions
            layer?.addSublayer(l)
            separators.append(l)
        }
        while separators.count > max(0, models.count - 1) { separators.removeLast().removeFromSuperlayer() }
        // The reset arrow shows on the drifted segment whose favicon is under the pointer.
        let arrow = hoveredFavicon.flatMap { models.indices.contains($0) && models[$0].drifted ? $0 : nil }
        for (k, (s, m)) in zip(segments, models).enumerated() {
            s.tabID = m.tabID
            s.paneID = m.paneID
            s.drifted = m.drifted
            if !s.title.attributedStringValue.isEqual(to: m.title) { s.title.attributedStringValue = m.title }
            s.favicon.set(image: m.image, url: m.iconURL, fallbackPage: m.page, palette: palette,
                          symbol: arrow == k ? "arrow.uturn.backward" : NoteURL.isNote(m.page) ? "note.text" : nil)
            s.favicon.alphaValue = arrow == k ? 1 : m.alpha
            s.badge.isHidden = m.badge == nil
            if let other = m.badge { LayerImage.set(ProfileAvatarImage.image(other, size: 11), on: s.badge, in: self) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in separators { l.backgroundColor = palette.textPrimary.withAlphaComponent(palette.isDark ? 0.18 : 0.14).cgColor }
        stacked.isHidden = axis != .vertical
        if axis == .vertical {
            LayerImage.set(LayerImage.symbol("rectangle.split.1x2", size: 11, weight: .medium, color: palette.textMuted), on: stacked, in: self)
        }
        CATransaction.commit()
        isSelected = selected
        updateStyle()
        needsLayout = true
    }

    /// Draws the row again from the store (a pane's page changed, the pointer moved onto a reset arrow).
    private func refresh() {
        guard let palette else { return }
        if let item = splitItem.flatMap({ controller?.store.item($0.id) }) {
            configure(splitItem: item, depth: depth, palette: palette, selected: isSelected, focusedTabID: focusedTabID)
        } else if let entry {
            configure(entry, palette: palette, selected: isSelected, focusedTabID: focusedTabID)
        }
    }

    /// SV-2: a pane of this pinned split changed (its title, icon, page): the row draws again. False for other rows.
    @discardableResult
    func refreshPane(_ tabID: String, palette: Palette, selected: Bool, focusedTabID: String?) -> Bool {
        guard let item = splitItem.flatMap({ controller?.store.item($0.id) }),
              segments.contains(where: { $0.tabID == tabID }) || controller?.store.tab(tabID).flatMap({ controller?.store.splitItem(ofPane: $0.itemID) })?.id == item.id
        else { return false }
        configure(splitItem: item, depth: depth, palette: palette, selected: selected, focusedTabID: focusedTabID)
        return true
    }

    private func makeClose() -> GlyphButton {
        if let close { return close }
        let b = GlyphButton(symbol: "xmark", size: 11)
        b.action = { [weak self] in
            guard let self else { return }
            if let item = self.splitItem {
                self.controller?.closeItemSplit(item.id)
                return
            }
            guard let i = self.hoveredSegment, self.segments.indices.contains(i) else { return }
            self.controller?.closeTab(self.segments[i].tabID)
        }
        b.isHidden = true
        addSubview(b)
        close = b
        return b
    }

    /// A pinned split's close is for the whole row, at its end, while any pane is loaded (✕; − while selected).
    private var closesWholeRow: Bool { splitItem != nil }

    override func updateStyle() {
        super.updateStyle()
        guard let palette else { return }
        let show: Bool
        if closesWholeRow {
            show = isHovered && !tabs.isEmpty
        } else {
            let i = hoveredSegment
            show = isHovered && i.map { segments.indices.contains($0) && segments[$0].frame.width >= Self.minTitled } == true
        }
        if show { makeClose() }
        close?.symbol = closesWholeRow && isSelected ? "minus" : "xmark"
        close?.tint = palette.textSecondary
        close?.hoverFill = palette.hover
        close?.isHidden = !show
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let indent = CGFloat(depth) * AircMetrics.Row.folderIndent
        let left = plateInsets.left + indent, right = bounds.width - plateInsets.right
        let glyph: CGFloat = axis == .vertical ? 18 : 0
        let rowClose = closesWholeRow && close?.isHidden == false ? AircMetrics.Row.closeButton : 0
        let n = CGFloat(max(segments.count, 1))
        let w = (right - left - glyph - rowClose) / n
        let fs = AircMetrics.Row.favicon
        for (k, s) in segments.enumerated() {
            let x0 = left + CGFloat(k) * w
            s.frame = NSRect(x: x0, y: 0, width: w, height: h)
            let titled = w >= Self.minTitled
            let iconX = titled ? x0 + 9 : x0 + (w - fs) / 2
            s.favicon.frame = NSRect(x: iconX, y: (h - fs) / 2, width: fs, height: fs)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            s.badge.frame = NSRect(x: s.favicon.frame.maxX - 7, y: s.favicon.frame.maxY - 7, width: 11, height: 11)
            CATransaction.commit()
            s.title.isHidden = !titled
            let closeRoom = (!closesWholeRow && isHovered && hoveredSegment == k && titled) ? AircMetrics.Row.closeButton : 0
            let tx = iconX + fs + 7
            s.title.frame = NSRect(x: tx, y: (h - 18) / 2, width: max(0, x0 + w - 6 - closeRoom - tx), height: 18)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, l) in separators.enumerated() {
            let x = left + CGFloat(k + 1) * w
            l.frame = NSRect(x: x - 0.5, y: (h - 18) / 2, width: 1, height: 18)
        }
        stacked.frame = NSRect(x: right - rowClose - glyph - 2, y: (h - 14) / 2, width: 14, height: 14)
        CATransaction.commit()
        let cb = AircMetrics.Row.closeButton
        if let close, closesWholeRow {
            close.frame = NSRect(x: bounds.width - AircMetrics.Sidebar.inset - 5 - cb, y: (h - cb) / 2, width: cb, height: cb)
        } else if let close, let i = hoveredSegment, segments.indices.contains(i) {
            let f = segments[i].frame
            close.frame = NSRect(x: f.maxX - 3 - cb, y: (h - cb) / 2, width: cb, height: cb)
        }
    }

    private func segment(at p: NSPoint) -> Int? { segments.firstIndex { $0.frame.contains(NSPoint(x: p.x, y: bounds.midY)) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func track(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredSegment = segment(at: p)
        hoveredFavicon = hoveredSegment.flatMap { k in
            segments[k].drifted && segments[k].favicon.frame.insetBy(dx: -4, dy: -4).contains(p) ? k : nil
        }
    }

    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        track(event)
        needsLayout = true
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredSegment = nil
        hoveredFavicon = nil
        needsLayout = true
    }

    /// The tab of the segment under a window point (a click there focuses that pane); nil over an unloaded pane.
    func tabID(at windowPoint: NSPoint) -> String? {
        segment(at: convert(windowPoint, from: nil)).flatMap { segments[$0].tabID.isEmpty ? nil : segments[$0].tabID }
    }

    /// A segment's centre, in window coordinates (the real-event checks click it).
    func segmentCentre(_ k: Int) -> NSPoint? {
        guard segments.indices.contains(k) else { return nil }
        let f = segments[k].frame
        return convert(NSPoint(x: f.midX, y: f.midY), to: nil)
    }

    /// A segment's favicon centre, in window coordinates (the reset arrow of a drifted pane).
    func faviconCentre(_ k: Int) -> NSPoint? {
        guard segments.indices.contains(k) else { return nil }
        let f = segments[k].favicon.frame
        return convert(NSPoint(x: f.midX, y: f.midY), to: nil)
    }

    /// The close button's centre, in window coordinates, while it shows.
    var closeCentre: NSPoint? {
        guard let close, !close.isHidden else { return nil }
        return close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
    }

    /// Whether a segment's favicon shows the reset arrow (a drifted pane under the pointer).
    func showsResetArrow(_ k: Int) -> Bool { hoveredFavicon == k }

    /// Segment titles as drawn (the checks read them).
    var segmentTitles: [String] { segments.map(\.title.stringValue) }
    /// Segment favicon alphas as drawn (unloaded panes are at half strength).
    var segmentAlphas: [CGFloat] { segments.map(\.favicon.alphaValue) }

    // Press activates on mouse-down (Arc), on the pane that was pressed. Dragging is handled by the page.
    override func mouseDown(with event: NSEvent) {
        guard let entry else { return }
        // Arc (1.17.2): ⌥-click separates the split into tabs; an ⌥-drag still drags it (Browser/SplitExtras.swift).
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .option, let c = controller, c.optionClickSplits(entry) {
            if page?.beginPossibleDrag(entry: entry, row: self, event: event) == false { c.optionClickSplit(entry) }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        let k = segment(at: p)
        if splitItem != nil, let k, segments[k].drifted, !segments[k].tabID.isEmpty,
           segments[k].favicon.frame.insetBy(dx: -4, dy: -4).contains(p) {
            // SV-2 / SB-31: "Back to pinned URL" for this pane; ⌘-click also keeps the current page in a new Today tab.
            controller?.resetToSaved(segments[k].tabID, keepCurrent: event.modifierFlags.contains(.command))
            return
        }
        if splitItem != nil {
            // SB-36: ⌘-click adds or removes the row, ⇧-click extends to it; the page shown stays.
            let flags = event.modifierFlags.intersection([.command, .shift])
            if !flags.isEmpty, let page {
                page.select(entry.id, extending: flags.contains(.shift))
                return
            }
            if page?.selection.contains(entry.id) != true { page?.clearSelection() }
        } else if let page, !page.selection.isEmpty {
            page.clearSelection()
        }
        isPressed = true
        pressAnimation()
        let before = controller?.shownTabID
        controller?.closeCommandBar()
        if let k, let pane = segments[k].paneID {
            controller?.openPane(pane)
        } else if let id = tabID(at: event.locationInWindow) {
            controller?.show(id)
        }
        page?.beginPossibleDrag(entry: entry, row: self, event: event, shownBefore: splitItem != nil ? before : nil)
    }

    override func mouseUp(with event: NSEvent) { isPressed = false }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        // Middle-click closes the pane under the pointer (a pinned split: the whole split, keeping the row).
        if let item = splitItem { controller?.closeItemSplit(item.id) } else if let id = tabID(at: event.locationInWindow) { controller?.closeTab(id) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entry else { return nil }
        if let page, page.selection.count > 1, page.selection.contains(entry.id) {
            return controller?.selectionMenu(ids: page.selection, spaceID: page.spaceID)
        }
        return controller?.menu(for: entry, pane: tabID(at: event.locationInWindow))
    }

    override var dragTitle: String { segments.map(\.title.stringValue).joined(separator: " | ") }
    override var dragFavicon: CGImage? { segments.first?.favicon.cgImage }
}
