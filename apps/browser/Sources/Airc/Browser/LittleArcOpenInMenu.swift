// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// LA-1: Arc's Open In menu, under Little Arc's chip (its chevron, ⇧⌘O and ⌥⌘O). Arc draws it in a window of its own,
/// not an NSMenu, and so does Airc: an NSMenu can't tint its rows or hold a search field.
///   - The short list: up to `collapsedLimit` Spaces in sidebar order (the chip's always among them), each by its icon
///     and name, its tile and highlight in its Space's colours. The chip's Space has ⌘O. A Space of another profile says
///     the page reloads there (a page can't change profile).
///   - "Search Spaces" under them expands it into a field that filters every Space as you type; typing anywhere in the
///     short list does the same.
///   - Profile ▸ and Copy Link (⇧⌘C) under a line: Arc keeps them in its toolbar, which Little Arc's row has no room for.
/// ↑ ↓ move the highlight (the chip's Space first), Return opens it, Esc closes; the pointer highlights the row it's on
/// and a click opens it. A click anywhere else, or the app going to the background, closes it. Keys come from Little
/// Arc's `handleKey` while its window is key (the panel never takes the keyboard for the short list, so Little Arc stays
/// the active window), and from the panel once the search field has the keyboard.
final class LittleArcOpenInMenu: NSObject, NSTextFieldDelegate {
    /// One Space of the list.
    struct Entry {
        let space: Space
        /// "Reloads in <profile>" for a Space of another profile.
        let note: String?
        /// The Space's own colours: its row's tile and highlight.
        let palette: Palette
    }

    enum Item: Equatable {
        case space(String), search, profile, copyLink
    }

    /// Spaces in the short list before "Search Spaces" (Arc's own count isn't known; the checks lower it).
    static var collapsedLimit = 6
    #if AIRC_TESTING
    /// For the checks: what the rows were sent (press, release, activation) and why the menu closed, with the panel's
    /// state at the time.
    static var trace: [String] = []
    static func note(_ line: String) { trace.append(line); if trace.count > 40 { trace.removeFirst() } }
    #endif
    /// Search results shown at most; a longer list says to keep typing.
    static let resultLimit = 10

    enum Metrics {
        static let width: CGFloat = 268
        static let inset: CGFloat = 6
        static let rowHeight: CGFloat = 32
        static let twoLineHeight: CGFloat = 42
        static let searchHeight: CGFloat = 36
        static let separator: CGFloat = 11
        static let rowRadius: CGFloat = AircRadius.control
        /// Concentric with the rows' plates.
        static var radius: CGFloat { rowRadius + inset }
        static let tile: CGFloat = 22
        static let tileRadius: CGFloat = 6
        static let tileX: CGFloat = 6
        static let textX: CGFloat = 38
        static let trailing: CGFloat = 10
        /// Under the chip.
        static let gap: CGFloat = 4
    }
    typealias M = Metrics

    let panel: LittleArcOpenInPanel
    let content = LittleArcOpenInView()
    let field = NSTextField()
    private let fieldGlyph = CALayer()
    private let emptyLabel = NSTextField(labelWithString: "")
    private(set) var rows: [LittleArcOpenInRow] = []
    private var separators: [CALayer] = []

    let entries: [Entry]
    let primaryID: String
    let palette: Palette
    private let profile: Profile?
    private let canCopy: Bool
    private let enabled: Bool

    private(set) var isShown = false
    private(set) var isExpanded = false
    private(set) var query = ""
    private(set) var highlighted: Item?

    var onOpen: ((String) -> Void)?
    var onProfile: ((NSView) -> Void)?
    var onCopyLink: (() -> Void)?
    /// A ⌘ key while the search field has the keyboard: the menu closes and Little Arc takes it.
    var onForward: ((NSEvent) -> Void)?
    var onClose: (() -> Void)?
    /// A press that should only close it (the chevron that opened it), not reach what's under it.
    var isToggle: ((NSEvent) -> Bool)?

    private weak var parent: NSWindow?
    private weak var anchor: NSView?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    init(entries: [Entry], primaryID: String, palette: Palette, profile: Profile?, canCopy: Bool, enabled: Bool) {
        self.entries = entries
        self.primaryID = primaryID
        self.palette = palette
        self.profile = profile
        self.canCopy = canCopy
        self.enabled = enabled
        panel = LittleArcOpenInPanel(contentRect: NSRect(x: 0, y: 0, width: M.width, height: 100),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.openIn = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = content
        content.wantsLayer = true
        content.layer?.cornerRadius = M.radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = palette.panelBackground.cgColor
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = palette.panelBorder.cgColor
        content.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        content.setAccessibilityRole(.group)
        content.setAccessibilityLabel("Open In")
        fieldGlyph.actions = LayerImage.noActions
        fieldGlyph.contentsGravity = .center
        content.layer?.addSublayer(fieldGlyph)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AircFont.body.nsFont
        field.textColor = palette.panelText
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderAttributedString = NSAttributedString(string: "Search Spaces", attributes: [
            .font: AircFont.body.nsFont, .foregroundColor: palette.resolved.surfaceTextTertiary.nsColor])
        field.delegate = self
        field.setAccessibilityLabel("Search Spaces")
        content.addSubview(field)
        emptyLabel.font = AircFont.body.nsFont
        emptyLabel.textColor = palette.resolved.surfaceTextTertiary.nsColor
        content.addSubview(emptyLabel)
    }

    // MARK: What it lists

    /// The short list: the first `collapsedLimit` Spaces in sidebar order, the chip's taking the last place if it's
    /// further down (the order stays the sidebar's).
    func shortList() -> [Entry] {
        let n = max(1, Self.collapsedLimit)
        guard entries.count > n else { return entries }
        var list = Array(entries.prefix(n))
        if !list.contains(where: { $0.space.id == primaryID }), let p = entries.first(where: { $0.space.id == primaryID }) {
            list[n - 1] = p
        }
        return list
    }

    /// Every Space whose name has the query, ignoring case and accents: names starting with it first, then a word
    /// starting with it, then the rest, each in sidebar order.
    func results() -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        func rank(_ name: String) -> Int? {
            guard let r = name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            if r.lowerBound == name.startIndex { return 0 }
            let before = name[name.index(before: r.lowerBound)]
            return before.isWhitespace || before.isPunctuation ? 1 : 2
        }
        return entries.enumerated().compactMap { i, e in rank(e.space.name).map { ($0, i, e) } }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    func row(_ item: Item) -> LittleArcOpenInRow? { rows.first { $0.item == item } }

    // MARK: Showing it

    /// Under `anchor` (the chip), its right edge with the chip's; `searching`: straight into Search Spaces (⌥⌘O).
    func show(under anchor: NSView, searching: Bool) {
        guard let parent = anchor.window, !isShown else { return }
        self.parent = parent
        self.anchor = anchor
        isExpanded = searching
        rebuild()
        highlighted = searching ? firstResult : (row(.space(primaryID)) != nil ? .space(primaryID) : rows.first?.item)
        restyleRows()
        place()
        panel.level = parent.level
        panel.alphaValue = 0
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AircCurve.previewIn.duration
            panel.animator().alphaValue = 1
        }
        isShown = true
        #if AIRC_TESTING
        Self.note("shown: panel #\(panel.windowNumber) visible \(panel.isVisible) frame \(panel.frame), parent #\(parent.windowNumber) key \(parent.isKeyWindow), "
                  + "app active \(NSApp.isActive)")
        #endif
        watch()
        if searching { focusField() }
    }

    func close(_ reason: String = "", file: String = #fileID, line: Int = #line) {
        guard isShown else { return }
        #if AIRC_TESTING
        Self.note("closed: " + (reason.isEmpty ? "\(file):\(line)" : reason))
        #endif
        isShown = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let hadKeyboard = panel.isKeyWindow
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if hadKeyboard, let parent, parent.isVisible { parent.makeKey() }
        onClose?()
    }

    /// A click elsewhere (in the app or another app), the app going to the background, or Little Arc closing or
    /// minimizing closes it; Little Arc moving or resizing takes it along.
    private func watch() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] e in
            #if AIRC_TESTING
            if let self, self.isShown {
                Self.note("monitor: \(e.type.rawValue) window #\(e.windowNumber) \(e.window.map { String(describing: type(of: $0)) } ?? "none"), the panel \(e.window === self.panel)")
            }
            #endif
            guard let self, self.isShown, e.window !== self.panel else { return e }
            let toggle = self.isToggle?(e) == true
            self.close(toggle ? "the chevron" : "a press elsewhere (window \(e.window.map { String(describing: type(of: $0)) } ?? "none") #\(e.windowNumber))")
            return toggle ? nil : e
        }) { monitors.append(m) }
        let center = NotificationCenter.default
        // Clicks in other apps (scripted runs leave these out: the owner's own clicks must not close a check's menu).
        if !LaunchOptions.current.isAutomated {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.close() }) {
                monitors.append(m)
            }
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.close()
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in self?.close() })
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in self?.place() })
        }
    }

    private func place() {
        guard let parent, let anchor else { return }
        let a = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let size = panel.frame.size
        var x = a.maxX - size.width
        var top = a.minY - M.gap
        if let screen = (parent.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
            if top - size.height < screen.minY + 4 { top = screen.minY + 4 + size.height }
        }
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    }

    // MARK: Rows

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperlayer() }
        rows = []
        separators = []
        var y = M.inset
        let tertiary = palette.resolved.surfaceTextTertiary.nsColor
        if isExpanded {
            field.isHidden = false
            fieldGlyph.isHidden = false
            LayerImage.set(LayerImage.symbol("magnifyingglass", size: 13, weight: .medium, color: tertiary), on: fieldGlyph, in: content)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fieldGlyph.frame = NSRect(x: M.inset + M.tileX, y: y + (M.searchHeight - M.tile) / 2, width: M.tile, height: M.tile)
            CATransaction.commit()
            field.frame = NSRect(x: M.inset + M.textX - 2, y: y + (M.searchHeight - 20) / 2, width: M.width - 2 * M.inset - M.textX - 4, height: 20)
            y += M.searchHeight
            addSeparator(&y)
            let found = results()
            for e in found.prefix(Self.resultLimit) { addSpace(e, &y) }
            emptyLabel.isHidden = found.count > 0 && found.count <= Self.resultLimit
            if !emptyLabel.isHidden {
                emptyLabel.stringValue = found.isEmpty ? "No Spaces match" : "\(found.count - Self.resultLimit) more: keep typing"
                emptyLabel.sizeToFit()
                emptyLabel.frame.origin = NSPoint(x: M.inset + M.textX - 2, y: y + (M.rowHeight - emptyLabel.frame.height) / 2)
                y += M.rowHeight
            }
        } else {
            field.isHidden = true
            fieldGlyph.isHidden = true
            emptyLabel.isHidden = true
            for e in shortList() { addSpace(e, &y) }
            addSeparator(&y)
            add(LittleArcOpenInRow(item: .search, menu: self), title: "Search Spaces", subtitle: nil, trailing: "",
                tile: .glyph("magnifyingglass"), label: "Search Spaces", &y)
            addSeparator(&y)
            add(LittleArcOpenInRow(item: .profile, menu: self), title: "Profile", subtitle: nil, trailing: profile?.name ?? "",
                tile: profile.map { LittleArcOpenInRow.Tile.image(ProfileAvatarImage.image($0, size: 18)) } ?? .glyph("person.crop.circle"),
                label: "Profile: \(profile?.name ?? "")", chevron: true, &y)
            add(LittleArcOpenInRow(item: .copyLink, menu: self), title: "Copy Link", subtitle: nil, trailing: "⇧⌘C",
                tile: .glyph("link"), label: "Copy Link", enabled: canCopy, &y)
        }
        y += M.inset
        resize(height: y)
    }

    private func addSpace(_ e: Entry, _ y: inout CGFloat) {
        let primary = e.space.id == primaryID
        add(LittleArcOpenInRow(item: .space(e.space.id), menu: self), title: e.space.name, subtitle: e.note, trailing: primary ? "⌘O" : "",
            tile: .space(e), label: "Open in \(e.space.name)", enabled: enabled, &y)
    }

    private func add(_ row: LittleArcOpenInRow, title: String, subtitle: String?, trailing: String, tile: LittleArcOpenInRow.Tile,
                     label: String, enabled: Bool = true, chevron: Bool = false, _ y: inout CGFloat) {
        let h = subtitle == nil ? M.rowHeight : M.twoLineHeight
        row.frame = NSRect(x: M.inset, y: y, width: M.width - 2 * M.inset, height: h)
        row.configure(title: title, subtitle: subtitle, trailing: trailing, tile: tile, chevron: chevron, palette: palette)
        row.isEnabled = enabled
        row.setAccessibilityLabel(label)
        row.setAccessibilityHelp(subtitle ?? (trailing.isEmpty || chevron ? nil : trailing))
        content.addSubview(row)
        rows.append(row)
        y += h
    }

    private func addSeparator(_ y: inout CGFloat) {
        let line = CALayer()
        line.actions = LayerImage.noActions
        line.backgroundColor = palette.separator.cgColor
        line.frame = NSRect(x: M.inset + 8, y: y + (M.separator - 1) / 2, width: M.width - 2 * M.inset - 16, height: 1 / max(1, panel.backingScaleFactor))
        content.layer?.addSublayer(line)
        separators.append(line)
        y += M.separator
    }

    /// Keeps the top where it is (under the chip) as the list grows or shrinks.
    private func resize(height: CGFloat) {
        let f = panel.frame
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - height, width: M.width, height: height), display: isShown)
        content.frame = NSRect(x: 0, y: 0, width: M.width, height: height)
        panel.invalidateShadow()
    }

    private func restyleRows() {
        for r in rows { r.isHighlighted = r.item == highlighted }
    }

    private var firstResult: Item? { rows.first { $0.isEnabled }?.item }

    // MARK: Acting

    func highlight(_ item: Item?) {
        guard highlighted != item else { return }
        highlighted = item
        restyleRows()
    }

    /// ↑ ↓: the next row that can act, round the ends as menus do.
    func move(_ delta: Int) {
        let items = rows.filter(\.isEnabled).map(\.item)
        guard !items.isEmpty else { return }
        let i = highlighted.flatMap { items.firstIndex(of: $0) } ?? (delta > 0 ? -1 : items.count)
        highlight(items[((i + delta) % items.count + items.count) % items.count])
    }

    func activate(_ item: Item) {
        #if AIRC_TESTING
        Self.note("activate \(item): row \(row(item) != nil), enabled \(row(item)?.isEnabled == true), shown \(isShown)")
        #endif
        guard let r = row(item), r.isEnabled else { return }
        switch item {
        case .space(let id):
            close()
            onOpen?(id)
        case .search:
            expand(query: "")
        case .profile:
            highlight(.profile)
            onProfile?(r)
        case .copyLink:
            close()
            onCopyLink?()
        }
    }

    func activateHighlighted() {
        if let highlighted { activate(highlighted) }
    }

    /// Search Spaces: the field at the top, every Space under it filtered by `query`.
    func expand(query q: String) {
        isExpanded = true
        query = q
        field.stringValue = q
        rebuild()
        highlighted = firstResult
        restyleRows()
        focusField()
    }

    /// The query changed (typed in the field, or keys handed over while the field hasn't the keyboard).
    func setQuery(_ q: String) {
        guard isExpanded else { return expand(query: q) }
        query = q
        if field.stringValue != q { field.stringValue = q }
        rebuild()
        highlighted = firstResult
        restyleRows()
    }

    /// The field takes the keyboard (the panel becomes key without activating the app). Scripted runs never take the
    /// keyboard: their keys come through `handleKey`.
    private func focusField() {
        guard isShown, !LaunchOptions.current.isAutomated else { return }
        panel.makeKey()
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    /// A key while it's up, from Little Arc (its window key) or the panel. True: the menu used it. A ⌘ or ⌃ key closes it
    /// and goes on to Little Arc (⌘O opens the chip's Space, ⇧⌘C copies the link, ⌘W closes the window…).
    func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.contains(.command) || mods.contains(.control) {
            close()
            return false
        }
        switch e.keyCode {
        case 53: close()                                                    // Esc
        case 125: move(1)                                                   // ↓
        case 126: move(-1)                                                  // ↑
        case 36, 76: activateHighlighted()                                  // Return, Enter
        case 124 where highlighted == .profile: activate(.profile)          // →
        case 51 where isExpanded: setQuery(String(query.dropLast()))        // Delete
        case 48, 51, 117, 123, 124, 115, 119, 116, 121: break               // Tab, Delete, arrows, Home/End, Page keys
        default:
            // Typing searches: the short list turns into Search Spaces with the typed text.
            let text = e.characters ?? ""
            let printable = !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0xF700 && $0.value != 0x7F }
            guard printable else { break }
            if isExpanded { setQuery(query + text) } else if !text.trimmingCharacters(in: .whitespaces).isEmpty { expand(query: text) }
        }
        return true
    }

    // MARK: NSTextFieldDelegate (the search field)

    func controlTextDidChange(_ obj: Notification) {
        setQuery(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): activateHighlighted()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
}

/// The Open In menu's window: borderless, a child of Little Arc's window. It takes the keyboard only for the search field
/// (`becomesKeyOnlyIfNeeded`), and never activates the app (it may sit over another app's full screen with Little Arc).
final class LittleArcOpenInPanel: NSPanel {
    weak var openIn: LittleArcOpenInMenu?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if openIn?.handleKey(event) != true { super.keyDown(with: event) }
    }

    /// With the keyboard (the search field): the field keeps its editing keys (the Edit menu's), and any other ⌘ key
    /// closes the menu and goes to Little Arc, never to the browser window's commands.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isKeyWindow, let menu = openIn else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let c = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command, ["a", "c", "v", "x", "z"].contains(c) { return false }
        if mods == [.command, .shift], c == "z" { return false }
        guard mods.contains(.command) || mods.contains(.control) else { return super.performKeyEquivalent(with: event) }
        menu.close()
        menu.onForward?(event)
        return true
    }
}

final class LittleArcOpenInView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One row of the Open In menu: a tile (a Space's, in its colours; or a glyph or avatar), the title and a second line,
/// and the key or value at the right. Highlighted (the pointer or the keyboard) it takes its tint: the Space's accent,
/// or the surface's hover for the other rows. A press acts on release over the row, as menus do.
final class LittleArcOpenInRow: NSView {
    enum Tile {
        case space(LittleArcOpenInMenu.Entry)
        case glyph(String)
        case image(NSImage)
    }
    typealias M = LittleArcOpenInMenu.Metrics

    let item: LittleArcOpenInMenu.Item
    private weak var owner: LittleArcOpenInMenu?
    private let plate = CALayer()
    private let tile = CAGradientLayer()
    private let tileImage = CALayer()
    private let chevron = CALayer()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    /// The highlight's fill (a Space's tint, the surface's hover for the others).
    private(set) var tint: NSColor = .clear
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4; setAccessibilityEnabled(isEnabled) } }
    var isHighlighted = false { didSet { if isHighlighted != oldValue { restyle() } } }
    private var pressed = false

    /// For the checks: what it shows.
    var titleText: String { title.stringValue }
    var subtitleText: String? { subtitle.isHidden ? nil : subtitle.stringValue }
    var trailingText: String { trailing.stringValue }
    var tileColors: [CGColor] { tile.isHidden ? [] : (tile.colors as? [CGColor]) ?? [] }
    var hasTileImage: Bool { tileImage.contents != nil }
    var plateFill: CGColor? { plate.backgroundColor }

    init(item: LittleArcOpenInMenu.Item, menu: LittleArcOpenInMenu) {
        self.item = item
        owner = menu
        super.init(frame: .zero)
        wantsLayer = true
        for l in [plate, tile, tileImage, chevron] as [CALayer] {
            l.actions = LayerImage.noActions
            layer?.addSublayer(l)
        }
        plate.cornerRadius = M.rowRadius
        plate.cornerCurve = .continuous
        tile.cornerRadius = M.tileRadius
        tile.cornerCurve = .continuous
        tile.startPoint = CGPoint(x: 0, y: 0)
        tile.endPoint = CGPoint(x: 1, y: 1)
        tileImage.contentsGravity = .center
        chevron.contentsGravity = .center
        for l in [title, subtitle, trailing] {
            l.lineBreakMode = .byTruncatingTail
            l.cell?.usesSingleLineMode = true
            addSubview(l)
        }
        title.font = AircFont.body.nsFont
        subtitle.font = AircFont.caption.nsFont
        trailing.font = AircFont.body.nsFont
        trailing.alignment = .right
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    func configure(title t: String, subtitle s: String?, trailing r: String, tile kind: Tile, chevron showsChevron: Bool, palette p: Palette) {
        title.stringValue = t
        title.textColor = p.panelText
        subtitle.stringValue = s ?? ""
        subtitle.isHidden = s == nil
        subtitle.textColor = p.panelSecondary
        trailing.stringValue = r
        trailing.textColor = showsChevron ? p.panelSecondary : p.resolved.surfaceTextTertiary.nsColor
        let size = M.tile
        switch kind {
        case .space(let e):
            tile.isHidden = false
            let colors = e.palette.resolved.gradient.map { $0.color.nsColor.cgColor }
            let fill = colors.isEmpty ? [e.palette.resolved.background.nsColor.cgColor] : colors
            tile.colors = fill.count == 1 ? [fill[0], fill[0]] : fill
            tile.borderWidth = 0.5
            tile.borderColor = p.panelBorder.cgColor
            tint = e.palette.resolved.accent.nsColor.withAlphaComponent(p.isDark ? 0.32 : 0.18)
            LayerImage.set(Self.icon(of: e, size: size), on: tileImage, in: self)
        case .glyph(let name):
            tile.isHidden = true
            tint = p.resolved.surfaceHover.nsColor
            LayerImage.set(LayerImage.symbol(name, size: 13, weight: .medium, color: p.panelSecondary), on: tileImage, in: self)
        case .image(let img):
            tile.isHidden = true
            tint = p.resolved.surfaceHover.nsColor
            LayerImage.set(img, on: tileImage, in: self)
        }
        LayerImage.set(showsChevron ? LayerImage.symbol("chevron.right", size: 10, weight: .semibold, color: p.panelSecondary) : nil,
                       on: chevron, in: self)
        needsLayout = true
        restyle()
    }

    /// A Space's tile picture: its emoji, its symbol, or its initial, in ink that reads on its colours.
    static func icon(of e: LittleArcOpenInMenu.Entry, size: CGFloat) -> NSImage? {
        let r = e.palette.resolved
        let mid = r.gradient.isEmpty ? r.background : r.gradient[r.gradient.count / 2].color
        let ink: NSColor = Self.luminance(mid.nsColor) > 0.55 ? NSColor.black.withAlphaComponent(0.78) : .white
        switch e.space.icon {
        case .emoji(let emoji)?:
            return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 13)])
                let b = text.size()
                text.draw(at: NSPoint(x: (rect.width - b.width) / 2, y: (rect.height - b.height) / 2))
                return true
            }
        case .symbol(let name)?:
            return LayerImage.symbol(name, size: 12, weight: .semibold, color: ink)
        case nil:
            let letter = e.space.name.first.map { String($0).uppercased() } ?? "?"
            return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                let text = NSAttributedString(string: letter, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink])
                let b = text.size()
                text.draw(at: NSPoint(x: (rect.width - b.width) / 2, y: (rect.height - b.height) / 2))
                return true
            }
        }
    }

    static func luminance(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
    }

    override func layout() {
        super.layout()
        let b = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = b
        let tileFrame = NSRect(x: M.tileX, y: (b.height - M.tile) / 2, width: M.tile, height: M.tile)
        tile.frame = tileFrame
        tileImage.frame = tileFrame
        let chevronW: CGFloat = chevron.contents == nil ? 0 : 12
        chevron.frame = NSRect(x: b.width - M.trailing - chevronW, y: 0, width: chevronW, height: b.height)
        CATransaction.commit()
        trailing.sizeToFit()
        let tw = trailing.stringValue.isEmpty ? 0 : min(trailing.frame.width, 110)
        let right = b.width - M.trailing - chevronW - (chevronW > 0 ? 4 : 0)
        trailing.frame = NSRect(x: right - tw, y: (b.height - 16) / 2, width: tw, height: 16)
        let textW = max(0, right - tw - (tw > 0 ? 8 : 0) - M.textX)
        if subtitle.isHidden {
            title.frame = NSRect(x: M.textX - 2, y: (b.height - 17) / 2, width: textW, height: 17)
        } else {
            title.frame = NSRect(x: M.textX - 2, y: b.height / 2 - 17, width: textW, height: 17)
            subtitle.frame = NSRect(x: M.textX - 2, y: b.height / 2 + 1, width: textW, height: 15)
        }
    }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = isHighlighted || pressed ? tint.cgColor : nil
        CATransaction.commit()
        setAccessibilitySelected(isHighlighted)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { if isEnabled { owner?.highlight(item) } }

    override func mouseDown(with event: NSEvent) {
        #if AIRC_TESTING
        LittleArcOpenInMenu.note("down \(item) enabled \(isEnabled) alpha \(window?.alphaValue ?? -1) visible \(window?.isVisible == true)")
        #endif
        guard isEnabled else { return }
        pressed = true
        owner?.highlight(item)
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != isHighlighted { owner?.highlight(inside ? item : nil) }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        #if AIRC_TESTING
        LittleArcOpenInMenu.note("up \(item) pressed \(pressed) inside \(inside)")
        #endif
        guard pressed else { return }
        pressed = false
        restyle()
        if inside { owner?.activate(item) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        owner?.activate(item)
        return true
    }
}
