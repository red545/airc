// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// The sidebar's tidy card (docs/user/sidebar.md, "Keeping your sidebar tidy"): when a Space's Today list gets long
/// (AircKit's `TidyHintRules`: 12 loose Today tabs, or 6 when Today is taller than the sidebar), a small card at the top
/// of Today offers, each in one click and each undoable from the toast it leaves:
///
/// - **Tidy N tabs into folders** (Tidy Tabs: by topic with Apple Intelligence, by site without it). The card then
///   shows the folders it would make; nothing moves until **Apply**.
/// - **Archive N tabs idle X h** (the longest of 6, 3 or 1 hours that catches three tabs or more).
/// - **Pin <site>** (to Favorites) for the one or two sites with the most Today tabs, so the grid gets used.
/// - **Archive Today tabs after**: the profile's auto-archive time, the same four choices as Settings › Profiles.
/// - **Not now**: no card again today.
///
/// Never automatic, and at most once a day on this Mac: any choice, or Not now, ends it for the day (a device-local
/// value, never synced). The preview shows whenever a tidy is waiting for Apply, also one started from the Today
/// header's Tidy or the Command Bar.
@MainActor
enum TidyHint {
    /// A tidy waiting for Apply, per Space, and whether it was grouped by site (no Apple Intelligence).
    struct Preview {
        var plan: TidyTabsPlan
        var bySite: Bool
    }
    private(set) static var previews: [String: Preview] = [:]

    static let dayKey = "tidyHint.doneDay"
    /// Scripted runs (Debug/TidyUXCheck.swift): the day it is.
    static var dayOverride: String?
    /// How often the card was put on screen fresh (not redrawn), per Space; the check reads it.
    private(set) static var appearances: [String: Int] = [:]

    #if AIRC_TESTING
    static var allowedInScripts = false
    private static let scripted = ProcessInfo.processInfo.arguments.contains("--script")
    #endif

    static func today() -> String { dayOverride ?? TidyHintRules.dayKey(Date()) }

    static func isDoneToday(_ store: SpacesStore) -> Bool { store.localValue(dayKey) == today() }

    static func doneForToday(_ store: SpacesStore) {
        store.setLocalValue(dayKey, today())
        reloadAll()
    }

    /// Whether the Space's list gets the card: a preview waiting, or a long Today not handled yet today.
    /// `overflows`: whether the list (without the card) is taller than the sidebar, asked only when the tab count alone
    /// doesn't decide; `looseCount` hears the loose tab count when it was counted.
    static func shows(_ c: WindowController, spaceID: String, today entries: [SidebarEntry], overflows: () -> Bool,
                      looseCount: (Int) -> Void = { _ in }) -> Bool {
        if previews[spaceID] != nil { return true }
        #if AIRC_TESTING
        // Scripted runs see the card only when they ask (tidyux, its marketing shot): other checks' rows stay put.
        if scripted, !allowedInScripts { return false }
        #endif
        if TidyTabsFeature.isRunning(spaceID) { return true }   // "Tidying…" with Stop, then the preview
        guard !isDoneToday(c.store) else { return false }
        let n = looseTabs(entries).count
        looseCount(n)
        guard n < TidyHintRules.tabThreshold else { return true }
        return TidyHintRules.isLong(looseTabs: n, overflows: n >= TidyHintRules.overflowThreshold && overflows())
    }

    static func looseTabs(_ entries: [SidebarEntry]) -> [LiveTab] {
        entries.compactMap { e -> LiveTab? in
            guard case .today(let t) = e, t.isToday, t.folderID == nil else { return nil }
            return t
        }
    }

    static func noteAppeared(_ spaceID: String) { appearances[spaceID, default: 0] += 1 }

    // MARK: What it offers

    struct Offer {
        var tidyCount: Int
        var archive: (age: TimeInterval, ids: [String])?
        var pins: [(host: String, tabID: String)]
        var archiveAfter: ArchiveInterval
    }

    static func offer(_ c: WindowController, spaceID: String) -> Offer {
        let s = c.store
        let loose = looseTabs(s.todayRows(ofSpace: spaceID))
        let pid = s.profile(ofSpace: spaceID).id
        let favoriteHosts = Set(s.favorites(ofProfile: pid).compactMap { f -> String? in
            let url = s.liveTab(forItem: f.id)?.url ?? f.savedURL
            return url.map(TidyTabsRules.host(of:))
        })
        return Offer(tidyCount: s.tidyCandidates(inSpace: spaceID).count,
                     archive: TidyHintRules.archiveOffer(loose, now: s.now(), protected: protected(c)),
                     pins: TidyHintRules.pinSuggestions(loose, favoriteHosts: favoriteHosts),
                     archiveAfter: s.profile(ofSpace: spaceID).archiveAfter)
    }

    /// Never archived from the card: the pages on screen.
    private static func protected(_ c: WindowController) -> Set<String> { c.visibleTabIDs }

    // MARK: Actions (each one click; each leaves a toast with Undo)

    /// The card offers Tidy only where Tidy is available (TidyTabsFeature.isAvailable) and there's enough to group;
    /// without it, the card still offers archiving old tabs and pinning.
    static func offersTidy(_ o: Offer) -> Bool {
        TidyTabsFeature.isAvailable && o.tidyCount >= TidyTabsRules.minPagesPerFolder
    }

    static func tidy(_ c: WindowController, spaceID: String) {
        doneForToday(c.store)
        TidyTabsFeature.start(in: c, spaceID: spaceID)
    }

    static func archiveOld(_ c: WindowController, spaceID: String) {
        guard let o = offer(c, spaceID: spaceID).archive else { return }
        doneForToday(c.store)
        let label = "Archive Old Tabs"
        c.closeThenArchive(o.ids, reason: .manual, label: label)
        let n = o.ids.filter { c.store.tab($0) == nil }.count
        guard n > 0 else { return }
        c.showUndoToast("Archived \(n) \(n == 1 ? "tab" : "tabs")", detail: "Library › Archive has them", label: label)
    }

    static func pin(_ c: WindowController, spaceID: String, tabID: String, host: String) {
        guard c.store.tab(tabID) != nil else { return }
        doneForToday(c.store)
        // One undoable step (a drag into Favorites isn't one), so the toast's Undo puts the tab back in Today.
        let pid = c.store.profile(ofSpace: spaceID).id
        let label = "Add to Favorites"
        do {
            let reload = try c.store.perform(label, undoable: true) {
                try c.store.move(.tab(tabID), to: .favorites(profileID: pid, index: c.store.favorites(ofProfile: pid).count))
            }
            c.reloadPagesInNewProfile(reload)
            Telemetry.shared.record(.featureUsed(.favoriteAdd))
        } catch StoreError.favoritesFull {
            return c.showToast("Favorites are full (12)")
        } catch {
            return NSSound.beep()
        }
        c.showUndoToast("Added \(host) to Favorites", detail: nil, label: label)
    }

    static func setArchiveAfter(_ c: WindowController, spaceID: String, _ v: ArchiveInterval) {
        let pid = c.store.profile(ofSpace: spaceID).id
        try? c.store.updateProfile(pid) { $0.archiveAfter = v }
        c.showToast(v.archives ? "Today tabs archive after \(v.label)" : "Today tabs never archive on their own")
    }

    static func notNow(_ c: WindowController) { doneForToday(c.store) }

    // MARK: The preview

    static func showPreview(_ plan: TidyTabsPlan, bySite: Bool) {
        previews[plan.spaceID] = Preview(plan: plan, bySite: bySite)
        reloadAll()
    }

    static func cancelPreview(_ spaceID: String) {
        guard previews.removeValue(forKey: spaceID) != nil else { return }
        reloadAll()
    }

    static func apply(_ c: WindowController, spaceID: String) {
        guard let p = previews.removeValue(forKey: spaceID) else { return }
        defer { reloadAll() }
        do {
            guard let record = try c.store.applyTidyTabs(p.plan) else {
                return c.showToast("Your tabs changed while tidying, so nothing was moved")
            }
            let n = record.moved.count, f = record.folderIDs.count
            c.showUndoToast("Grouped \(n) \(n == 1 ? "tab" : "tabs") into \(f) \(f == 1 ? "folder" : "folders")",
                            detail: nil, label: SpacesStore.tidyTabsLabel)
        } catch {
            c.showToast("Couldn’t tidy tabs")
        }
    }

    static func reloadAll() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        for w in app.controllers { w.scheduleReload() }
    }
}

extension WindowController {
    /// A toast with Undo for the step just taken (`label` is its undo step's name). Undo runs ⌘Z's undo only while
    /// that step is still the last one; otherwise it says so and changes nothing.
    func showUndoToast(_ text: String, detail: String?, label: String) {
        guard let step = store.undoStack.last, step.label == label else { return showToast(text) }
        let serial = step.serial
        toast.show(text, palette: currentPalette, in: card.frame, duration: AircMetrics.Toast.fullScreenDuration,
                   action: (title: "Undo", run: { [weak self] in
                       guard let self else { return }
                       self.toast.dismiss()
                       guard self.store.undoStack.last?.serial == serial else {
                           return self.showToast("Something else changed since, so use Edit › Undo")
                       }
                       self.undo()
                   }), detail: detail)
    }
}

// MARK: - The card

/// One action line in the card: a symbol and a title; hover fills it, a click (or VoiceOver's press) runs it.
final class TidyHintButton: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private var run: (() -> Void)?
    private var hovered = false
    private var palette: Palette?
    private var prominent = false
    private var area: NSTrackingArea?
    /// The check reads what a line says.
    var titleText: String { title.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        title.font = AircFont.body.appFont
        title.lineBreakMode = .byTruncatingMiddle
        title.cell?.truncatesLastVisibleLine = true
        addSubview(icon)
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, symbol: String?, palette: Palette, prominent: Bool = false, tooltip: String? = nil,
                   run: @escaping () -> Void) {
        self.palette = palette
        self.prominent = prominent
        self.run = run
        if title.stringValue != text { title.stringValue = text }
        title.font = prominent ? AircFont.body.weight(.semibold).appFont : AircFont.body.appFont
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.isHidden = icon.image == nil
        toolTip = tooltip
        setAccessibilityLabel(text.hasPrefix("Pin ") ? text + " to Favorites" : text)
        recolor()
        needsLayout = true
    }

    private func recolor() {
        guard let p = palette else { return }
        let ink = prominent ? NSColor.controlAccentColor : p.textPrimary
        title.textColor = ink
        icon.contentTintColor = prominent ? ink : p.textSecondary
        layer?.backgroundColor = (hovered ? p.hover : .clear).cgColor
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 6
        if !icon.isHidden {
            icon.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
            x += 22
        }
        title.sizeToFit()
        let th = title.frame.height
        title.frame = NSRect(x: x, y: (h - th) / 2, width: max(0, bounds.width - x - 6), height: th)
    }

    /// How wide the line wants to be (for buttons side by side).
    var fittingWidth: CGFloat {
        title.sizeToFit()
        return title.frame.width + (icon.isHidden ? 12 : 34)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; recolor() }
    override func mouseExited(with event: NSEvent) { hovered = false; recolor() }
    override func mouseDown(with event: NSEvent) { layer?.backgroundColor = palette?.pressed.cgColor }
    override func mouseUp(with event: NSEvent) {
        recolor()
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        run?()
    }
    override func accessibilityPerformPress() -> Bool { run?(); return run != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    func press() { run?() }
}

/// The card's background: a press on it doesn't drag the window or reach the rows below.
final class TidyHintPlate: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
}

/// The card as a sidebar row (SpacePage's `.tidyHint`), like `DefaultBrowserCardView`: the offer, a tidy under way, or
/// the folders a tidy would make with Apply and Cancel.
final class TidyHintCardView: SidebarRowView {
    enum Mode: Equatable { case offer, working, preview }

    private let cardPlate = TidyHintPlate()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private(set) var buttons: [String: TidyHintButton] = [:]
    private var lines: [NSTextField] = []
    private let archiveLabel = NSTextField(labelWithString: "Archive after")
    let archivePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var mode: Mode = .offer
    var spaceID = ""
    private var order: [String] = []
    private var lineTexts: [String] = []
    private var archiveChoices: [ArchiveInterval] = ArchiveInterval.allCases

    static let padding: CGFloat = 10
    static let buttonHeight: CGFloat = 26
    static let lineHeight: CGFloat = 20

    override init(frame: NSRect) {
        super.init(frame: frame)
        showsPlate = false
        cardPlate.wantsLayer = true
        cardPlate.layer?.cornerRadius = AircMetrics.Profile.signInCardRadius
        cardPlate.layer?.cornerCurve = .continuous
        addSubview(cardPlate)
        title.font = AircFont.body.weight(.semibold).appFont
        subtitle.font = AircFont.micro.appFont
        subtitle.lineBreakMode = .byTruncatingTail
        archiveLabel.font = AircFont.micro.appFont
        archivePopUp.controlSize = .small
        archivePopUp.font = AircFont.micro.appFont
        archivePopUp.target = self
        archivePopUp.action = #selector(archiveChosen)
        archivePopUp.setAccessibilityLabel("Archive Today tabs after")
        for v in [title, subtitle, archiveLabel, archivePopUp] as [NSView] { cardPlate.addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tidy your sidebar")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }

    func button(_ key: String) -> TidyHintButton? { buttons[key] }

    private func setButton(_ key: String, _ text: String, symbol: String?, prominent: Bool = false, tooltip: String? = nil,
                           run: @escaping () -> Void) {
        let b: TidyHintButton
        if let old = buttons[key] {
            b = old
        } else {
            b = TidyHintButton()
            cardPlate.addSubview(b)
            buttons[key] = b
        }
        b.configure(text, symbol: symbol, palette: palette!, prominent: prominent, tooltip: tooltip, run: run)
        order.append(key)
    }

    func configure(spaceID: String, palette: Palette) {
        self.spaceID = spaceID
        self.palette = palette
        guard let c = controller else { return }
        order = []
        cardPlate.layer?.backgroundColor = palette.resolved.sidebarCardFill.nsColor.cgColor
        title.textColor = palette.textPrimary
        subtitle.textColor = palette.textSecondary
        archiveLabel.textColor = palette.textSecondary
        let sid = spaceID
        if TidyTabsFeature.isRunning(sid) {
            mode = .working
            title.stringValue = "Tidying…"
            subtitle.stringValue = TidyTabsFeature.usesAppleIntelligence ? "Sorting tabs by topic on this Mac" : "Grouping tabs by site"
            setButton("stop", "Stop", symbol: "xmark") { TidyTabsFeature.cancel(spaceID: sid) }
            lineTexts = []
        } else if let p = TidyHint.previews[sid] {
            mode = .preview
            let f = p.plan.folders.count, n = p.plan.tabCount
            title.stringValue = "Tidy \(n) tabs into \(f) \(f == 1 ? "folder" : "folders")?"
            subtitle.stringValue = p.bySite ? "Grouped by site. Nothing moves until you apply." : "Grouped by topic. Nothing moves until you apply."
            var texts = p.plan.folders.prefix(6).map { "\($0.name)  ·  \($0.tabIDs.count)" }
            if p.plan.folders.count > 6 { texts.append("and \(p.plan.folders.count - 6) more") }
            lineTexts = texts
            setButton("apply", "Apply", symbol: "checkmark", prominent: true, tooltip: "Make these folders (Undo puts them back)") { [weak c] in
                guard let c else { return }
                TidyHint.apply(c, spaceID: sid)
            }
            setButton("cancel", "Cancel", symbol: nil) { TidyHint.cancelPreview(sid) }
        } else {
            mode = .offer
            let o = TidyHint.offer(c, spaceID: sid)
            let loose = TidyHint.looseTabs(c.store.todayRows(ofSpace: sid)).count
            title.stringValue = "Today has \(loose) tabs"
            subtitle.stringValue = "Each one can be undone"
            lineTexts = []
            if TidyHint.offersTidy(o) {
                let how = TidyTabsFeature.usesAppleIntelligence ? "by topic" : "by site"
                setButton("tidy", "Tidy \(o.tidyCount) tabs into folders", symbol: "square.stack.3d.down.right",
                          tooltip: "Groups Today’s tabs into folders \(how). Shows them first; nothing moves until you apply") { [weak c] in
                    guard let c else { return }
                    TidyHint.tidy(c, spaceID: sid)
                }
            }
            if let a = o.archive {
                setButton("archive", "Archive \(a.ids.count) tabs idle \(TidyHintRules.shortAgeLabel(a.age))", symbol: "archivebox",
                          tooltip: "Archives the \(a.ids.count) tabs you haven’t viewed in \(TidyHintRules.ageLabel(a.age)) (Undo brings them back)") { [weak c] in
                    guard let c else { return }
                    TidyHint.archiveOld(c, spaceID: sid)
                }
            }
            for (i, p) in o.pins.enumerated() {
                setButton("pin\(i)", "Pin \(p.host)", symbol: "star",
                          tooltip: "Pin \(p.host) to Favorites, the grid at the top of every Space of this profile") { [weak c] in
                    guard let c else { return }
                    TidyHint.pin(c, spaceID: sid, tabID: p.tabID, host: p.host)
                }
            }
            archiveChoices = ArchiveInterval.choices(current: o.archiveAfter)
            if archivePopUp.itemTitles != archiveChoices.map(\.label) {
                archivePopUp.removeAllItems()
                archivePopUp.addItems(withTitles: archiveChoices.map(\.label))
            }
            archivePopUp.selectItem(at: archiveChoices.firstIndex(of: o.archiveAfter) ?? 0)
            setButton("notnow", "Not now", symbol: nil, tooltip: "No tidy card again today") { [weak c] in
                guard let c else { return }
                TidyHint.notNow(c)
            }
        }
        for (k, b) in buttons where !order.contains(k) {
            b.removeFromSuperview()
            buttons[k] = nil
        }
        while lines.count < lineTexts.count {
            let l = NSTextField(labelWithString: "")
            l.font = AircFont.body.appFont
            l.lineBreakMode = .byTruncatingTail
            cardPlate.addSubview(l)
            lines.append(l)
        }
        for (i, l) in lines.enumerated() {
            l.isHidden = i >= lineTexts.count
            if i < lineTexts.count { l.stringValue = lineTexts[i]; l.textColor = palette.textPrimary }
        }
        let showsArchive = mode == .offer
        archiveLabel.isHidden = !showsArchive
        archivePopUp.isHidden = !showsArchive
        needsLayout = true
    }

    @objc private func archiveChosen() {
        let i = archivePopUp.indexOfSelectedItem
        guard let c = controller, archiveChoices.indices.contains(i) else { return }
        TidyHint.setArchiveAfter(c, spaceID: spaceID, archiveChoices[i])
    }

    /// The row's height for what it shows (plus 8 pt below), from the same counts `layout` uses.
    static func height(_ c: WindowController, spaceID: String) -> CGFloat {
        let p = padding
        let head: CGFloat = 18 + 16 + 6
        if TidyTabsFeature.isRunning(spaceID) { return p + head + buttonHeight + p + 8 }
        if let pv = TidyHint.previews[spaceID] {
            let lines = CGFloat(min(pv.plan.folders.count, 6) + (pv.plan.folders.count > 6 ? 1 : 0))
            return p + head + lines * lineHeight + 6 + buttonHeight + p + 8
        }
        let o = TidyHint.offer(c, spaceID: spaceID)
        let actions = CGFloat((TidyHint.offersTidy(o) ? 1 : 0) + (o.archive == nil ? 0 : 1) + o.pins.count)
        return p + head + actions * buttonHeight + 4 + 22 + 2 + buttonHeight + p + 8
    }

    override func layout() {
        super.layout()
        let inset = AircMetrics.Sidebar.inset
        cardPlate.frame = NSRect(x: inset, y: isFlipped ? 0 : 8, width: bounds.width - 2 * inset, height: max(0, bounds.height - 8))
        let p: CGFloat = Self.padding, w: CGFloat = cardPlate.bounds.width - 2 * p
        // cardPlate is not flipped: lay out top-down with y measured from the top.
        let H: CGFloat = cardPlate.bounds.height
        func place(_ v: NSView, y: CGFloat, h: CGFloat, x: CGFloat? = nil, width: CGFloat? = nil) {
            v.frame = NSRect(x: x ?? p, y: H - y - h, width: width ?? w, height: h)
        }
        var y = p
        place(title, y: y, h: 18)
        y += 18
        place(subtitle, y: y, h: 16)
        y += 16 + 6
        switch mode {
        case .working:
            if let b = buttons["stop"] { place(b, y: y, h: Self.buttonHeight, x: p - 6, width: w + 12) }
        case .preview:
            for l in lines where !l.isHidden {
                place(l, y: y, h: Self.lineHeight, x: p + 4, width: w - 4)
                y += Self.lineHeight
            }
            y += 6
            let cancel = buttons["cancel"], apply = buttons["apply"]
            let aw = apply?.fittingWidth ?? 0, cw = cancel?.fittingWidth ?? 0
            if let apply { place(apply, y: y, h: Self.buttonHeight, x: p + w - aw + 6, width: aw) }
            if let cancel { place(cancel, y: y, h: Self.buttonHeight, x: p + w - aw - cw - 2, width: cw) }
        case .offer:
            for k in order where k != "notnow" {
                guard let b = buttons[k] else { continue }
                place(b, y: y, h: Self.buttonHeight, x: p - 6, width: w + 12)
                y += Self.buttonHeight
            }
            y += 4
            archivePopUp.sizeToFit()
            let pw = min(archivePopUp.frame.width, w * 0.45)
            place(archiveLabel, y: y + 3, h: 16, width: w - pw - 4)
            place(archivePopUp, y: y, h: 22, x: p + w - pw, width: pw)
            y += 22 + 2
            if let b = buttons["notnow"] {
                let bw = b.fittingWidth
                place(b, y: y, h: Self.buttonHeight, x: p + w - bw + 6, width: bw)
            }
        }
    }
}
