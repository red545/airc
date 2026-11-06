// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// Saved logins to choose from (SB-3, engine pass 12): when a site has several, the engine replaces Chromium's popup
/// with rows the app draws, a list hanging under the focused field. A row is a username and the site, with the engine's
/// opaque handle; no password ever reaches the app. Choosing one asks the engine to fill it (Chromium fills, with its
/// own checks); Esc, a click elsewhere, the page scrolling or navigating, or the field changing take it away.
///
/// The page keeps the keyboard: ↑ ↓ move the selection, Return fills, Esc closes (an app-level key monitor while the
/// list is up), and every other key still types into the field (the engine sends the rows again as they narrow).
struct PasswordChoice: Equatable {
    /// The engine's handle for this row (never reused in the tab; not an array offset).
    let index: Int
    let username: String
    let site: String
    /// The field's rectangle in the page view, top-left origin, when the engine sends it (`bounds`).
    let fieldRect: NSRect?

    init?(_ d: [String: String]) {
        guard d["type"] == "password", let i = d["index"].flatMap(Int.init) else { return nil }
        index = i
        username = d["label"] ?? ""
        site = d["sublabel"] ?? ""
        fieldRect = d["bounds"].map(NSRectFromString).flatMap { $0.width > 0 ? $0 : nil }
    }
}

// MARK: - The list

final class PasswordPickerView: NSView {
    static let rowHeight: CGFloat = 44
    static let inset: CGFloat = 5
    static let minWidth: CGFloat = 260
    static let maxWidth: CGFloat = 380
    static let maxRows = 6

    private(set) var choices: [PasswordChoice] = []
    private(set) var rows: [PasswordRowView] = []
    /// The selected row (keyboard or hover); nil until one is.
    private(set) var selected: Int?
    var onChoose: ((PasswordChoice) -> Void)?
    private let theme: ResolvedTheme
    private let scroll = NSScrollView()
    private let list = FlippedView()

    init(theme: ResolvedTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.menu
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = theme.surface.nsColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = theme.surfaceBorder.nsColor.cgColor
        layer?.applyAircShadow(.popover)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = AircRadius.menu
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.masksToBounds = true
        addSubview(scroll)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Saved passwords")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// A press between rows does nothing (the root would drag the window) and leaves the page its keyboard.
    override func mouseDown(with event: NSEvent) {}

    var preferredHeight: CGFloat {
        CGFloat(min(choices.count, Self.maxRows)) * Self.rowHeight + 2 * Self.inset
    }

    func set(_ choices: [PasswordChoice]) {
        let keep = selected.flatMap { i in self.choices.indices.contains(i) ? self.choices[i].username : nil }
        self.choices = choices
        while rows.count < choices.count {
            let r = PasswordRowView(theme: theme)
            r.onHover = { [weak self, weak r] in
                guard let self, let r, let i = self.rows.firstIndex(where: { $0 === r }) else { return }
                self.select(i)
            }
            r.onClick = { [weak self, weak r] in
                guard let self, let r, let i = self.rows.firstIndex(where: { $0 === r }), i < self.choices.count else { return }
                self.select(i)
                self.onChoose?(self.choices[i])
            }
            list.addSubview(r)
            rows.append(r)
        }
        for (i, r) in rows.enumerated() {
            r.isHidden = i >= choices.count
            if i < choices.count { r.configure(choices[i]) }
        }
        // The same login stays selected while the list narrows as the person types.
        select(keep.flatMap { u in choices.firstIndex { $0.username == u } })
        needsLayout = true
    }

    func select(_ i: Int?) {
        selected = i
        for (j, r) in rows.enumerated() { r.isSelected = j == i }
        if let i, rows.indices.contains(i) { list.scrollToVisible(rows[i].frame) }
    }

    /// ↓ / ↑: the next or previous row, wrapping; the first press selects the first (or last) row.
    func move(_ step: Int) {
        guard !choices.isEmpty else { return }
        guard let s = selected else { return select(step > 0 ? 0 : choices.count - 1) }
        select((s + step + choices.count) % choices.count)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let w = bounds.width
        list.frame = NSRect(x: 0, y: 0, width: w, height: CGFloat(choices.count) * Self.rowHeight + 2 * Self.inset)
        for (i, r) in rows.enumerated() where i < choices.count {
            r.frame = NSRect(x: Self.inset, y: Self.inset + CGFloat(i) * Self.rowHeight, width: w - 2 * Self.inset, height: Self.rowHeight)
        }
    }

    /// Drops 4 pt and fades in on the dialog curve (as the prompt cards do).
    func present() {
        guard let layer else { return }
        let curve = AircCurve.dialog
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = -4
        drop.toValue = 0
        drop.duration = curve.duration
        drop.timingFunction = curve.timingFunction
        layer.add(drop, forKey: "drop")
        layer.fade(from: 0, to: 1, duration: 0.12)
    }
}

final class PasswordRowView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { restyle() } } }
    private let theme: ResolvedTheme
    private let plate = NSImageView()
    private let user = AircFadingLabel(style: AircFont.row)
    private let site = AircFadingLabel(style: AircFont.callout)

    init(theme: ResolvedTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.menu - PasswordPickerView.inset
        layer?.cornerCurve = .continuous
        plate.image = Symbols.image("key.fill", size: 12, weight: .medium)
        plate.imageScaling = .scaleNone
        plate.contentTintColor = theme.surfaceTextSecondary.nsColor
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 8
        plate.layer?.cornerCurve = .continuous
        plate.layer?.backgroundColor = theme.tileFill.nsColor.cgColor
        user.textColor = theme.surfaceText.nsColor
        site.textColor = theme.surfaceTextSecondary.nsColor
        for v in [plate, user, site] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(_ c: PasswordChoice) {
        let name = c.username.isEmpty ? "No username" : c.username
        if user.stringValue != name { user.stringValue = name }
        user.textColor = c.username.isEmpty ? theme.surfaceTextTertiary.nsColor : theme.surfaceText.nsColor
        let where_ = c.site.isEmpty ? "Saved password" : c.site
        if site.stringValue != where_ { site.stringValue = where_ }
        setAccessibilityLabel("\(name), \(where_)")
        needsLayout = true
    }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = isSelected ? theme.surfaceSelected.nsColor.cgColor : NSColor.clear.cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        plate.frame = NSRect(x: 8, y: (h - 26) / 2, width: 26, height: 26)
        let x: CGFloat = 44
        user.frame = NSRect(x: x, y: 6, width: bounds.width - x - 10, height: 18)
        site.frame = NSRect(x: x, y: 24, width: bounds.width - x - 10, height: 15)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

// MARK: - The controller (one per window, with its prompts)

final class PasswordPicker {
    unowned let host: PromptHost
    /// Asks the engine to fill a row (true: it did) and to take the rows away.
    var accept: ((EngineTab, Int) -> Bool)?
    var dismiss: ((EngineTab) -> Void)?
    private(set) var view: PasswordPickerView?
    private(set) weak var page: EngineTab?
    private(set) var choices: [PasswordChoice] = []
    /// The field in the page view's coordinates (flipped, top-left origin), and where it came from (for checks).
    private(set) var fieldRect: NSRect?
    private(set) var anchorSource = "none"
    private var keyMonitor: Any?
    private var generation = 0
    /// Every row filled through the list, for the checks (username only).
    private(set) var filled: [String] = []
    /// The gap between the field and the list.
    static let gap: CGFloat = 4

    init(host: PromptHost) { self.host = host }

    deinit { if let m = keyMonitor { NSEvent.removeMonitor(m) } }

    /// The engine's rows for `page` (empty: take the list away).
    func update(_ items: [[String: String]], page: EngineTab) {
        let rows = items.compactMap(PasswordChoice.init)
        if items.isEmpty { return hide(page: page) }
        // A report of Chromium's own popup (addresses, cards): not ours.
        guard !rows.isEmpty else { return }
        guard page === host.promptShownPage, !page.isClosed else { return dismiss?(page) ?? () }
        let samePage = self.page === page && view != nil
        self.page = page
        choices = rows
        let v: PasswordPickerView
        if let existing = view, samePage {
            v = existing
        } else {
            hide(animated: false)
            v = PasswordPickerView(theme: host.promptTheme)
            v.onChoose = { [weak self] c in self?.choose(c) }
            host.promptRoot.addSubview(v)
            view = v
            installKeys()
        }
        v.set(rows)
        if let r = rows.first?.fieldRect {
            fieldRect = r
            anchorSource = "engine"
            layout()
        } else if !samePage || fieldRect == nil {
            locateField(page: page, showing: v)
        } else {
            layout()
        }
        if !samePage { v.present() }
    }

    /// Where the focused field is: the page's own answer (its focused element), else the text input's caret line,
    /// else under the URL field like the prompt cards. The list shows at once; it moves when the page answers.
    private func locateField(page: EngineTab, showing v: PasswordPickerView) {
        generation += 1
        let token = generation
        fieldRect = caretRect(in: page)
        anchorSource = fieldRect == nil ? "url field" : "caret"
        layout()
        let script = """
            (function(){var e=document.activeElement;while(e&&e.shadowRoot&&e.shadowRoot.activeElement)e=e.shadowRoot.activeElement;\
            if(!e||e===document.body||e===document.documentElement)return null;var r=e.getBoundingClientRect();\
            return [r.left,r.top,r.width,r.height,window.devicePixelRatio||1];})()
            """
        page.evaluate(script) { [weak self, weak page] value in
            guard let self, let page, token == self.generation, self.page === page,
                  let a = value as? [Any], a.count == 5 else { return }
            let n = a.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard n.count == 5, n[2] > 0, n[3] > 0 else { return }
            // CSS pixels to points: the page's zoom is devicePixelRatio over the screen's scale.
            let scale = page.view.window?.backingScaleFactor ?? 2
            let zoom = CGFloat(n[4]) / scale
            self.fieldRect = NSRect(x: n[0] * zoom, y: n[1] * zoom, width: n[2] * zoom, height: n[3] * zoom)
            self.anchorSource = "page"
            self.layout()
        }
    }

    /// The caret's line from the page's text input client (what places the input method's window), in the page view's
    /// flipped coordinates: a field's left edge isn't known this way, so it's the caret's.
    private func caretRect(in page: EngineTab) -> NSRect? {
        guard let w = page.view.window, let r = w.firstResponder as? NSView, r === page.view || r.isDescendant(of: page.view),
              let client = r as? NSTextInputClient else { return nil }
        let screen = client.firstRect(forCharacterRange: client.selectedRange(), actualRange: nil)
        guard screen.height > 0, screen != .zero else { return nil }
        let inView = page.view.convert(w.convertFromScreen(screen), from: nil)
        let flipped = page.view.isFlipped ? inView : NSRect(x: inView.minX, y: page.view.bounds.height - inView.maxY,
                                                            width: inView.width, height: inView.height)
        // The field's padding around its text, about Chrome's default.
        return flipped.insetBy(dx: -4, dy: -5)
    }

    /// Under the field (above it when there's no room below), as wide as the field within its limits, inside the page.
    func layout() {
        guard let v = view, let page else { return }
        let root = host.promptRoot
        let pageRect = root.convert(page.view.bounds, from: page.view)
        let field: NSRect
        if let r = fieldRect {
            let origin = page.view.isFlipped ? NSPoint(x: r.minX, y: r.minY) : NSPoint(x: r.minX, y: page.view.bounds.height - r.maxY)
            let local = NSRect(origin: origin, size: r.size)
            field = root.convert(local, from: page.view)
        } else {
            let a = host.promptAnchor()
            field = root.convert(a.rect, from: a.view)
        }
        let width = min(PasswordPickerView.maxWidth, max(PasswordPickerView.minWidth, field.width))
        let height = v.preferredHeight
        var y = field.maxY + Self.gap
        if y + height > pageRect.maxY - 8, field.minY - Self.gap - height >= pageRect.minY + 8 { y = field.minY - Self.gap - height }
        let x = min(max(pageRect.minX + 8, field.minX), pageRect.maxX - width - 8)
        v.frame = NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    private func choose(_ c: PasswordChoice) {
        guard let page else { return }
        // The engine refuses a choice in the first 500 ms (an accidental click) or for a field that changed: the list
        // stays as it is for a deliberate one.
        guard accept?(page, c.index) == true else { return }
        filled.append(c.username)
        hide(animated: true, keepPage: false)
    }

    /// The engine took the rows away (or the page went): the list goes.
    func hide(page: EngineTab) {
        guard self.page === page || view == nil else { return }
        hide(animated: true, keepPage: false)
    }

    /// Esc, a tab or Space switch, the window closing: the list goes and the engine forgets the rows.
    func close() {
        guard let page, view != nil else { return }
        hide(animated: false, keepPage: false)
        dismiss?(page)
    }

    private func hide(animated: Bool, keepPage: Bool = true) {
        generation += 1
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if !keepPage { page = nil; choices = []; fieldRect = nil }
        guard let v = view else { return }
        view = nil
        guard animated else { return v.removeFromSuperview() }
        v.layer?.fade(from: 1, to: 0, duration: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { v.removeFromSuperview() }
    }

    /// ↑ ↓ Return Esc while the list is up and its page has the keyboard; everything else goes to the page.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let v = self.view, let page = self.page, event.window === self.host.promptRoot.window,
                  let r = event.window?.firstResponder as? NSView, r === page.view || r.isDescendant(of: page.view) else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return event }
            switch event.keyCode {
            case 125: v.move(1); return nil              // ↓
            case 126: v.move(-1); return nil             // ↑
            case 36, 76:                                 // Return, Enter
                guard let i = v.selected, i < self.choices.count else { return event }
                self.choose(self.choices[i])
                return nil
            case 53: self.close(); return nil            // Esc
            default: return event
            }
        }
    }
}
