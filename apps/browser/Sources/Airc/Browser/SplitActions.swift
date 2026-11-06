// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

// SV-1 Split View, the ways in and out (spec §2.16b, Arc ref §2.11 and §5): a tab dragged onto a tab (SpacePage) or
// onto the page, ⌃⇧+ and the "+" menu (the Command Bar's pick opens as the new pane), Peek's Split button, the Today
// tab menu's Add Split View; Separate All Tabs, ⌘W / ⌃⇧− on the focused pane, ⌘[ / ⌘] and ⌃⇧1–4 between panes.

extension WindowController {
    /// ⌃⇧+ / "+" → New Split View: the Command Bar opens, and what's picked there becomes a new pane next to `anchor`.
    struct PendingSplit {
        var anchor: String
        var axis: SplitAxis
        var token = UUID()
    }

    static let splitFullMessage = "A split holds up to 4 tabs"

    // MARK: Ways in

    /// ⌃⇧+, "+" → New Split View / New Bottom Split, the Today tab menu's Add Split View.
    func newSplitView(axis: SplitAxis = .horizontal, anchor: String? = nil) {
        guard let anchor = anchor ?? shownTabID, store.tab(anchor) != nil else { return openCommandBar(mode: .newTab) }
        if let x = store.split(containing: anchor), x.tabIDs.count >= Split.maxPanes { return showToast(Self.splitFullMessage) }
        if anchor != shownTabID { show(anchor, focus: false) }
        closeCommandBar()
        pendingSplit = PendingSplit(anchor: anchor, axis: store.split(containing: anchor)?.axis ?? axis)
        openCommandBar(mode: .newTab)
    }

    /// The Command Bar's pick while a New Split View waits for it. True when it went into the split.
    func performSplitPick(_ action: CommandResult.Action, typed: Bool) -> Bool {
        guard let p = pendingSplit else { return false }
        pendingSplit = nil
        let anchorTab = store.tab(p.anchor)
        // A new Today tab is a row of the split's Space, at the anchor's place.
        let spaceID = store.split(containing: p.anchor)?.spaceID ?? anchorTab?.spaceID ?? currentSpaceID
        let id: String?
        switch action {
        case .open(let url):
            let t = try? store.openTab(url: url.absoluteString, inSpace: store.space(spaceID) != nil ? spaceID : currentSpaceID,
                                       background: true, activate: false)
            if let t, typed { markTyped(t.id) }
            id = t?.id
        case .tab(let tid):
            id = tid == p.anchor ? nil : tid
        case .item(let iid):
            id = (try? store.openItem(iid, inSpace: currentSpaceID, activate: false))?.id
        case .space, .run:
            return false
        }
        guard let id else { return false }
        addPane(id, nextTo: p.anchor, axis: p.axis)
        return true
    }

    /// `tabID` becomes a pane just after `anchor` (a new split of the two, or one more pane in the anchor's), focused.
    func addPane(_ tabID: String, nextTo anchor: String, axis: SplitAxis, leading: Bool = false) {
        do {
            if let x = store.split(containing: anchor) {
                guard !x.tabIDs.contains(tabID) else { return show(tabID) }
                let i = (x.tabIDs.firstIndex(of: anchor) ?? x.tabIDs.count - 1) + (leading ? 0 : 1)
                try store.addToSplit(x.id, tabID: tabID, at: i)
                Telemetry.shared.record(.featureUsed(.splitCreate(panes: x.tabIDs.count + 1)))
            } else {
                let a = store.tab(anchor)
                let spaceID = currentSpaceID
                let order = a.flatMap { $0.isToday && $0.spaceID == spaceID ? $0.order : nil }
                try store.createSplit(leading ? [tabID, anchor] : [anchor, tabID], inSpace: spaceID, axis: axis,
                                      focused: tabID, order: order)
                Telemetry.shared.record(.featureUsed(.splitCreate(panes: 2)))
            }
            show(tabID)
        } catch StoreError.splitFull {
            showToast(Self.splitFullMessage)
        } catch {
            NSSound.beep()
        }
    }

    /// A sidebar drop onto a Today row (SpacePage.dropDestination → `.split`): the split shows, the dropped tab focused.
    func performSplitDrop(_ source: DragSource, to destination: DropDestination) {
        guard case .tab(let id) = source else { return NSSound.beep() }
        do {
            _ = try store.move(source, to: destination)
            if let n = store.split(containing: id)?.tabIDs.count { Telemetry.shared.record(.featureUsed(.splitCreate(panes: n))) }
            if case .split(let sid, _, _) = destination, sid != currentSpaceID { switchToSpace(sid, animated: true) }
            // SV-2: a pane of a pinned split now: the split opens (every pane), the dropped tab focused.
            if let pane = store.tab(id)?.itemID, store.splitItem(ofPane: pane) != nil, let t = try? store.openItem(pane, inSpace: currentSpaceID) {
                return show(t.id)
            }
            show(id)
        } catch StoreError.splitFull {
            showToast(Self.splitFullMessage)
        } catch {
            NSSound.beep()
        }
    }

    /// Where a tab dragged from the sidebar over the page would go, with the preview showing it; nil (and no preview)
    /// when it can't go there: not a Today tab, the tab on screen, a full split, or not over the page.
    func splitDropZone(for source: DragSource, at p: NSPoint) -> SplitDropZone? {
        let shownSplit = store.split(shownSplitID)
        guard case .tab(let id) = source, store.tab(id)?.isToday == true, let shown = shownTabID, id != shown,
              shownSplit?.tabIDs.contains(id) != true, (shownSplit?.tabIDs.count ?? 1) < Split.maxPanes,
              card.frame.insetBy(dx: 24, dy: 24).contains(p), !sidebar.frame.contains(p) else {
            hideSplitDropPreview()
            return nil
        }
        let page = card.frame
        var zone = SplitDropZone.at(p, in: page)
        if let x = shownSplit {
            // One more pane at the start or the end of the split.
            zone.axis = x.axis
            zone.leading = x.axis == .horizontal ? p.x < page.midX : p.y < page.midY
        }
        let n = CGFloat(shownSplit?.tabIDs.count ?? 1)
        let g = SplitContainerView.gap
        let share = 1 / (n + 1)
        let rect: NSRect
        switch (zone.axis, zone.leading) {
        case (.horizontal, true): rect = NSRect(x: page.minX, y: page.minY, width: page.width * share - g / 2, height: page.height)
        case (.horizontal, false): rect = NSRect(x: page.maxX - page.width * share + g / 2, y: page.minY, width: page.width * share - g / 2, height: page.height)
        case (.vertical, true): rect = NSRect(x: page.minX, y: page.minY, width: page.width, height: page.height * share - g / 2)
        case (.vertical, false): rect = NSRect(x: page.minX, y: page.maxY - page.height * share + g / 2, width: page.width, height: page.height * share - g / 2)
        }
        splitDropPreview.show(rect, palette: currentPalette)
        return zone
    }

    func hideSplitDropPreview() { splitDropPreview.hide() }

    /// The drop over the page: the dragged tab joins the page on screen in a split, on the side it was dropped.
    func dropOnPage(_ tabID: String, zone: SplitDropZone) {
        hideSplitDropPreview()
        guard let shown = shownTabID, shown != tabID else { return }
        addPane(tabID, nextTo: shownSplitID.flatMap { store.split($0) }.map { zone.leading ? $0.tabIDs[0] : $0.tabIDs[$0.tabIDs.count - 1] } ?? shown,
                axis: zone.axis, leading: zone.leading)
    }

    /// PK-1 → SV-1: Peek's Split button. The same page (no reload) becomes a Today tab in a split with the page under the
    /// card, which keeps the keyboard's pane next to it.
    func splitPeek() {
        guard let p = peek, !p.closing, !p.page.isClosed, let anchor = shownTabID else { return }
        if let x = store.split(containing: anchor), x.tabIDs.count >= Split.maxPanes { return showToast(Self.splitFullMessage) }
        let url = p.page.url?.absoluteString ?? "about:blank"
        guard let t = try? store.openTab(url: url, inSpace: currentSpaceID, openerID: p.openerTabID, background: true,
                                         activate: false, title: p.page.title) else { return }
        peek = nil
        adopt(p.page, as: t.id)
        p.view.removeFromSuperview()
        addPane(t.id, nextTo: anchor, axis: .horizontal)
        scheduleReload()
    }

    // MARK: In a split

    /// ⌃⇧1–4.
    func focusPane(number n: Int) {
        guard let x = store.split(shownSplitID), n >= 1, n <= x.tabIDs.count else { return NSSound.beep() }
        focusSplitPane(x.tabIDs[n - 1])
    }

    /// ⌃⇧−: the focused pane closes (as ⌘W does in a split).
    func closeFocusedPane() {
        guard shownSplitID != nil, let id = shownTabID else { return NSSound.beep() }
        closeTab(id)
    }

    /// Dragging a pane out by its handle (SV-1): the pane lifts as a row and the sidebar shows where it would land, as
    /// for a dragged tab. Dropped there it leaves the split and becomes a tab of its own in that place (Today, Pinned,
    /// Favorites, or onto a Today tab for a new split with it); the rest of the split stays on screen.
    /// Anywhere else, or Esc, puts it back.
    func dragPaneOut(_ tabID: String, event: NSEvent) {
        guard let x = store.split(shownSplitID), x.tabIDs.contains(tabID), let pane = splitContainer.pane(for: tabID),
              let page = pageView(for: currentSpaceID) else { return }
        let start = event.locationInWindow
        var dragging = false
        var ghost: AircDragGhostLayer?
        var overlay: NSView?
        var destination: DropDestination?
        pane.handle.isDragging = true
        dragsInProgress += 1
        defer { dragsInProgress -= 1 }
        tracking: while true {
            guard let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture,
                                           inMode: .eventTracking, dequeue: true) else { continue }
            switch e.type {
            case .keyDown where e.keyCode == 53:
                destination = nil
                break tracking
            case .leftMouseUp:
                break tracking
            case .leftMouseDragged:
                if !dragging {
                    guard hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > AircSpacing.xs else { continue }
                    dragging = true
                    let width = sidebar.frame.width - 2 * AircMetrics.Sidebar.inset
                    let g = AircDragGhostLayer(kind: .row, width: width, theme: currentPalette.resolved, scale: window.backingScaleFactor)
                    let t = store.tab(tabID)
                    let p = engineTab(for: tabID)
                    g.configure(title: p?.title.isEmpty == false ? p!.title : (t?.displayTitle ?? ""),
                                favicon: p?.favicon?.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    let o = FlippedView(frame: root.bounds)
                    o.wantsLayer = true
                    root.addSubview(o)
                    o.layer?.addSublayer(g)
                    ghost = g
                    overlay = o
                    pane.animator().alphaValue = 0.45
                    NSCursor.closedHand.set()
                }
                if let overlay, let g = ghost {
                    let w = overlay.convert(e.locationInWindow, from: nil)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    g.frame.origin = CGPoint(x: w.x - 28, y: w.y - g.bounds.height / 2)
                    CATransaction.commit()
                }
                destination = page.paneDropDestination(tabID, at: e.locationInWindow)
            default:
                break
            }
        }
        pane.handle.isDragging = false
        page.endPaneDrag()
        ghost?.removeFromSuperlayer()
        overlay?.removeFromSuperview()
        pane.alphaValue = 1
        NSCursor.arrow.set()
        guard dragging, let destination else { return }
        // The rest of the split stays on screen (or, down to one, that tab alone).
        let rest = x.tabIDs.filter { $0 != tabID }
        let keep = rest.contains(shownTabID ?? "") ? shownTabID! : (x.focusedTabID.flatMap { rest.contains($0) ? $0 : nil } ?? rest.first)
        performDrop(.tab(tabID), to: destination)
        if case .split = destination { return }
        if let keep, store.tab(keep) != nil { show(keep, focus: false) }
    }

    /// "Separate All Tabs": the panes become tabs of their own where the split's row was; the focused one stays shown.
    func separateSplit(_ splitID: String) {
        let focused = shownSplitID == splitID ? shownTabID : nil
        guard (try? store.separateSplit(splitID)) != nil else { return NSSound.beep() }
        if let focused { show(focused) }
    }

    func separateShownSplit() {
        guard let id = shownSplitID else { return NSSound.beep() }
        separateSplit(id)
    }

    /// The split row's menu (a segment's pane first, when the menu was opened over one).
    func menu(for entry: SidebarEntry, pane: String?) -> NSMenu {
        if let item = entry.item, item.kind == .split { return itemSplitMenu(item, pane: pane) }
        guard case .split(let x, let tabs) = entry else { return menu(for: entry) }
        let m = NSMenu()
        if let pane, let t = tabs.first(where: { $0.id == pane }) {
            let name = "“" + TextLimits.clip(engineTab(for: t.id)?.title.isEmpty == false ? engineTab(for: t.id)!.title : t.displayTitle) + "”"
            m.add("Copy Link") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.engineTab(for: t.id)?.url?.absoluteString ?? t.url, forType: .string)
                self.showToast("Copied Link")
            }
            m.add("Separate \(name)") { [weak self] in
                guard let self else { return }
                let focused = self.shownTabID
                try? self.store.removeFromSplit(t.id)
                if let focused, self.store.tab(focused) != nil { self.show(focused) }
            }
            m.add("Close \(name)", "⌘W") { [weak self] in self?.closeTab(t.id) }
            m.addItem(.separator())
        }
        m.add(x.axis == .horizontal ? "Arrange Top to Bottom" : "Arrange Side by Side") { [weak self] in
            try? self?.store.setSplitAxis(x.id, x.axis == .horizontal ? .vertical : .horizontal)
        }
        m.add("Make Panes the Same Size") { [weak self] in
            guard let self else { return }
            if self.shownSplitID == x.id { self.splitContainer.equalize() }
            else { self.store.setSplitFractions(x.id, Array(repeating: 1, count: x.tabIDs.count)) }
        }
        if tabs.count == 2 { m.add("Swap Panes") { [weak self] in try? self?.store.movePane(x.id, from: 0, to: 1) } }
        if tabs.count < Split.maxPanes {
            m.add("Add Split View", "⌃⇧+") { [weak self] in
                guard let self else { return }
                self.newSplitView(axis: x.axis, anchor: tabs.last(where: { $0.id == x.focusedTabID })?.id ?? tabs.last?.id)
            }
        }
        m.addItem(.separator())
        m.add("Separate All Tabs") { [weak self] in self?.separateSplit(x.id) }
        m.add("Close Split") { [weak self] in
            guard let self else { return }
            let today = tabs.filter(\.isToday).map(\.id)
            tabs.filter { !$0.isToday }.forEach { self.closeTab($0.id) }
            self.closeThenArchive(today, reason: .manual, label: "Close Split")
        }
        return m
    }
}
