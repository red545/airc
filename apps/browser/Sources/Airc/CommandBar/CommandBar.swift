// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

enum CommandBarMode: Equatable {
    /// ⌘T or "+ New Tab": creates no tab until you pick something (CB-1).
    case newTab
    /// ⌘L or a click on the URL field: starts on the current URL.
    case editURL
}

/// One result row.
struct CommandResult {
    enum Action {
        case open(URL)
        case tab(String)
        case item(String)
        case space(String)
        case run(() -> Void)
    }
    var title: String
    var subtitle: String
    var badge: String
    var icon: Icon
    var matches: [Int]
    var action: Action
    /// An action's shortcut as keycaps ("⇧", "⌘", "C"), shown on its row (design.md §7 "Command bar").
    var shortcut: [String] = []

    /// "⌥⇧⌘C" → ["⌥", "⇧", "⌘", "C"]: one keycap per modifier, then the key.
    static func keys(of hint: String) -> [String] {
        let modifiers: Set<Character> = ["⌘", "⌥", "⇧", "⌃"]
        var keys: [String] = []
        var rest = Substring(hint)
        while let c = rest.first, modifiers.contains(c) { keys.append(String(c)); rest = rest.dropFirst() }
        if !rest.isEmpty { keys.append(String(rest)) }
        return keys
    }

    enum Icon {
        case favicon(image: NSImage?, url: String?, page: String?)
        /// A built-in site (CommonSites): its favicon, a letter tile until it arrives.
        case site(page: String, name: String)
        case symbol(String)
        case emoji(String)
    }
}

/// What the Command Bar asks of the window it opens in: the main window (its Space's profile, SP-24) or a private
/// window (its own tabs only, no history).
protocol CommandBarHost: AnyObject {
    /// "🏡 Personal": whose results these are; nil hides the chip.
    var commandBarChip: String? { get }
    /// ⌘L and a click on the URL field open the bar over the field (the docked sidebar shows it).
    var commandBarAnchorsToURLField: Bool { get }
    /// The history searched off the main thread, and the profile it's for; nil searches none.
    var commandBarHistory: (store: HistoryStore, profileID: String)? { get }
    /// The search engine and the session key for live suggestions; nil while they're off.
    var commandBarSuggestions: (engine: SearchEngine, profileID: String)? { get }
    func inlineCompletion(for typed: String) -> InlineCompletion.Match?
    func siteCompletion(for typed: String, history: [HistoryMatch]) -> CommonSites.Completion?
    func commandResults(for query: String, mode: CommandBarMode, inline: InlineCompletion.Match?,
                        inlineSite: CommonSites.Site?, suggestions: [String], history: [HistoryMatch]) -> [CommandResult]
    func closeCommandBar()
    func performCommand(_ action: CommandResult.Action, newTab: Bool, typed: Bool)
}

/// The Command Bar (CB-1, Arc ref §5): a centred 765 pt panel, 64 pt input row, opens in one frame. ⌘L and a click on
/// the URL field open it over the URL field instead, as Arc does. Typing completes known addresses inline
/// (`InlineCompletion`); "/" or Tab on an empty field switches to actions only.
final class CommandBarView: NSView, NSTextFieldDelegate {
    weak var host: CommandBarHost?
    private(set) var mode: CommandBarMode
    var palette: Palette { didSet { applyPalette() } }
    private let panel = FlippedView()
    /// Shadow behind the panel, drawn from shadow paths in its own view so nothing clips it and Core Animation
    /// never renders it offscreen. Without it the bar disappears into white pages.
    private let shadowView = NSView()
    private let ambientShadow = CALayer()
    private let input = NSTextField()
    /// The edit in progress deletes text: don't complete it again (backspace over a completion removes it).
    private var deletingEdit = false
    private let glass = NSImageView()
    private let chip = NSTextField(labelWithString: "")
    private let chipBackground = CALayer()
    private let separator = CALayer()
    private var rows: [CommandRowView] = []
    private(set) var results: [CommandResult] = []
    private(set) var selected = 0
    private(set) var panelRect = NSRect.zero
    private var sidebarFrame = NSRect.zero
    private var contentFrame = NSRect.zero
    /// What the user actually typed (the field may also hold a selected inline completion).
    private(set) var typed = ""
    private var suggestions: [String] = []
    private var suggestionQuery = ""
    /// The last history matches (searched off the main thread, H5) and the query they were for.
    private var historyHits: [HistoryMatch] = []
    #if AIRC_TESTING
    /// Debug hook: history matches were applied to the rows (`--script cbperf`).
    var onHistoryApplied: ((Int) -> Void)?
    #endif
    /// The inline completion shown after the caret, if any.
    private(set) var inline: InlineCompletion.Match?
    /// The built-in site the inline completion came from, when nothing of yours completed what was typed.
    private(set) var inlineSite: CommonSites.Site?

    init(mode: CommandBarMode, palette: Palette, host: CommandBarHost) {
        self.mode = mode
        self.palette = palette
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        panel.wantsLayer = true
        panel.layer?.cornerRadius = AircMetrics.CommandBar.radius
        panel.layer?.cornerCurve = .continuous
        shadowView.wantsLayer = true
        shadowView.layer?.addSublayer(ambientShadow)
        addSubview(shadowView)
        addSubview(panel)
        glass.image = Symbols.image("magnifyingglass", size: 17, weight: .medium)
        glass.imageScaling = .scaleNone
        panel.addSubview(glass)
        input.font = AircFont.commandInput.appFont
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.placeholderString = "Search or Enter URL…"
        input.delegate = self
        input.cell?.isScrollable = true
        input.cell?.wraps = false
        // A URL field, not a login field: without this, becoming first responder runs AppKit's password and
        // one-time-code AutoFill heuristics on every opening (~1.4 ms, §2.12).
        input.contentType = .URL
        input.isAutomaticTextCompletionEnabled = false
        panel.addSubview(input)
        chip.font = AircFont.caption.appFont
        chip.alignment = .center
        chip.wantsLayer = true
        panel.layer?.addSublayer(chipBackground)
        panel.addSubview(chip)
        panel.layer?.addSublayer(separator)
        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Speed pass (first frame ≤ 8 ms): the window keeps one bar and reuses it, rows included, instead of building
    /// the panel, its fields and its rows on every ⌘T. This starts it over for the next opening. The rows keep their
    /// results until the opening's own `update` (so the panel doesn't shrink and grow back in the same frame).
    func reuse(mode: CommandBarMode, palette: Palette) {
        self.mode = mode
        typed = ""
        inline = nil
        inlineSite = nil
        suggestions = []
        suggestionQuery = ""
        historyHits = []
        deletingEdit = false
        if !input.stringValue.isEmpty { input.stringValue = "" }
        // Restyling with the same palette re-set every row and the field, which then measured and redrew (§2.12).
        if self.palette != palette { self.palette = palette } else { updateChip() }
    }

    /// Between openings the bar stays in the window, drawn, but parked outside it, instead of hidden: unhiding its ~80
    /// views and redrawing the rows whose text had changed since it last showed were most of a ⌘T after the recent
    /// tabs changed (~17 ms against ~9, §2.12). Parked, it takes no clicks, hover, cursor or keyboard and has no
    /// accessibility children; `prepareForNextOpening` keeps its rows what ⌘T will show.
    private(set) var isParked = false

    func park() {
        isParked = true
        input.refusesFirstResponder = true
        if let sv = superview { layoutIn(sv.bounds, sidebarFrame: sidebarFrame, contentFrame: contentFrame) }
    }

    func unpark() {
        isParked = false
        input.refusesFirstResponder = false
    }

    /// At idle, while parked: what ⌘T will show (this Space's chip and palette, the profile's recent tabs, the window's
    /// size), set now so Core Animation draws it in an idle frame, and the opening only moves the bar in and focuses it.
    func prepareForNextOpening(palette: Palette, in bounds: NSRect, sidebarFrame: NSRect, contentFrame: NSRect) {
        guard isParked else { return }
        let timing = Perf.enabled
        Perf.enabled = false
        defer { Perf.enabled = timing }
        reuse(mode: .newTab, palette: palette)
        layoutIn(bounds, sidebarFrame: sidebarFrame, contentFrame: contentFrame)
        update(allowCompletion: false)
    }

    /// Laid out for this window size and page card (the parked bar is refreshed at idle when not, e.g. after ⌘S).
    func isLaidOut(in bounds: NSRect, contentFrame: NSRect) -> Bool {
        frame.size == bounds.size && self.contentFrame == (contentFrame.isEmpty ? bounds : contentFrame)
    }

    override func accessibilityChildren() -> [Any]? { isParked ? [] : super.accessibilityChildren() }

    /// The first ⌘T used to make the window's field editor and AppKit's text-input UI (`TUINSCursorUIController`, a
    /// window of its own) in its frame: ~10–15 ms of the 15–19 ms first opening (§2.12). Both are made here, at idle,
    /// without moving the keyboard: the editor directly, the rest by a field in a window that is never shown.
    func prewarmEditing() {
        _ = window?.fieldEditor(true, for: input)
        TextInputWarmup.run()
    }

    /// Builds the row views ahead (hidden), so the first opening doesn't create them.
    func preloadRows(_ n: Int) {
        while rows.count < n { rows.append(makeRow()) }
        for r in rows { r.isHidden = true }
    }

    private func makeRow() -> CommandRowView {
        let r = CommandRowView()
        r.palette = palette
        r.onClick = { [weak self, weak r] in
            guard let self, let r, let i = self.rows.firstIndex(where: { $0 === r }) else { return }
            self.selected = i
            self.execute()
        }
        r.onHover = { [weak self, weak r] in
            guard let self, !self.isParked, let r, let i = self.rows.firstIndex(where: { $0 === r }), i < self.results.count else { return }
            self.select(i)
        }
        panel.addSubview(r)
        return r
    }

    func focus(with text: String) {
        input.stringValue = text
        typed = text
        window?.makeFirstResponder(input)
        input.currentEditor()?.selectAll(nil)
        update(allowCompletion: false)
    }

    /// Types `text` as the keyboard would (scenarios, perf): when it goes on from what was typed, each further character
    /// goes in through the field editor at its selection (over an inline completion), which tells the delegate as a key
    /// press does. Anything else replaces the field. (Making the field first responder again here, as this used to,
    /// ends and restarts its editing session: ~4 ms a keystroke that typing never costs.)
    func type(_ text: String) {
        guard let editor = input.currentEditor() as? NSTextView, window?.firstResponder === editor else {
            window?.makeFirstResponder(input)
            input.stringValue = text
            textDidChange(byDeleting: false)
            return
        }
        guard text.hasPrefix(typed) else {
            // Something else: as if the field's text were selected and typed over.
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            return
        }
        for ch in text.dropFirst(typed.count) {
            editor.insertText(String(ch), replacementRange: editor.selectedRange())
        }
    }

    /// The field's own editor (WindowController hands it out for `input`): no spelling, grammar or autocorrection
    /// checks, no text replacement or inline predictions. The window's shared editor ran AppKit's text checking on
    /// every keystroke (§2.12), which an address field (Chrome's, Arc's) doesn't do.
    lazy var fieldEditor: NSTextView = {
        let editor = NSTextView(frame: .zero)
        editor.isFieldEditor = true
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        if #available(macOS 14.0, *) { editor.inlinePredictionType = .no }
        return editor
    }()

    func isInput(_ client: Any?) -> Bool { (client as AnyObject?) === input }

    var query: String { typed }
    var inlineText: String? { inline?.text }
    var resultTitles: [String] { results.map { $0.title + ($0.subtitle.isEmpty ? "" : " (\($0.badge))") } }
    var isActionsMode: Bool { typed.hasPrefix("/") }

    private func applyPalette() {
        panel.layer?.backgroundColor = palette.panelBackground.cgColor
        // The shadow view carries the panel's shape too (hidden behind it), so the shadow renders even if
        // AppKit ignores the shadow path.
        shadowView.layer?.backgroundColor = palette.panelBackground.cgColor
        shadowView.layer?.cornerRadius = AircMetrics.CommandBar.radius
        shadowView.layer?.cornerCurve = .continuous
        shadowView.layer?.masksToBounds = false
        let elevation = AircShadow.commandBar
        shadowView.layer?.applyAircShadow(AircShadow(Array(elevation.layers.prefix(1))))
        ambientShadow.applyAircShadow(AircShadow(Array(elevation.layers.dropFirst())))
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = palette.panelBorder.cgColor
        input.textColor = palette.panelText
        input.placeholderAttributedString = NSAttributedString(string: "Search or Enter URL…", attributes: [
            .foregroundColor: palette.panelSecondary, .font: AircFont.commandInput.appFont])
        glass.contentTintColor = palette.panelSecondary
        separator.backgroundColor = palette.panelBorder.cgColor
        chip.textColor = palette.panelSecondary
        chipBackground.backgroundColor = palette.resolved.surfaceHover.cgColor
        chipBackground.cornerRadius = 12
        rows.forEach { $0.palette = palette }
        updateChip()
    }

    private func updateChip() {
        guard let host else { return }
        // Results come from this profile only (SP-24); the chip says which.
        let text = host.commandBarChip ?? ""
        if chip.stringValue != text { chip.stringValue = text }
        let hidden = host.commandBarChip == nil
        if chip.isHidden != hidden { chip.isHidden = hidden }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chipBackground.isHidden = hidden
        CATransaction.commit()
    }

    /// Opened from the URL field: the panel grows out of `field` (in this view's coordinates) to its own rect with the
    /// `grow` spring; the input row stays centred on the field, so the text doesn't move. The shadow fades in with it.
    func grow(from field: NSRect) {
        guard let layer = panel.layer, !panelRect.isEmpty else { return }
        let full = CGRect(origin: .zero, size: panelRect.size)
        let start = CGRect(x: field.minX - panelRect.minX, y: field.minY - panelRect.minY, width: field.width, height: field.height)
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.cornerCurve = .continuous
        mask.frame = full
        mask.cornerRadius = AircMetrics.CommandBar.radius
        layer.mask = mask
        let spring = AircSpring.grow
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak mask] in
            guard let self, let mask, self.panel.layer?.mask === mask else { return }
            self.panel.layer?.mask = nil
        }
        mask.add(spring.caAnimation(keyPath: "bounds", from: NSValue(rect: CGRect(origin: .zero, size: start.size)),
                                    to: NSValue(rect: CGRect(origin: .zero, size: full.size))), forKey: "grow.bounds")
        mask.add(spring.caAnimation(keyPath: "position", from: NSValue(point: NSPoint(x: start.midX, y: start.midY)),
                                    to: NSValue(point: NSPoint(x: full.midX, y: full.midY))), forKey: "grow.position")
        mask.add(spring.caAnimation(keyPath: "cornerRadius", from: AircRadius.row, to: AircMetrics.CommandBar.radius),
                 forKey: "grow.radius")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = spring.settlingDuration
        shadowView.layer?.add(fade, forKey: "grow.fade")
        CATransaction.commit()
    }

    // The sidebar stays clickable while the bar is open; a click anywhere else closes it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if sidebarFrame.contains(p) && !panelRect.contains(p) { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panelRect.contains(p) { host?.closeCommandBar() }
    }

    /// Over the URL field (⌘L, click) when the sidebar is docked; centred otherwise (⌘T, hidden sidebar). Its left edge
    /// is the field's and its input row is centred on the field, so it reads as the field growing (Arc ref §2.2).
    private func anchoredRect(in bounds: NSRect, height: CGFloat) -> NSRect? {
        guard mode == .editURL, host?.commandBarAnchorsToURLField == true else { return nil }
        let x = sidebarFrame.minX + AircMetrics.Sidebar.inset
        let fieldMid = AircMetrics.Sidebar.urlFieldTop + AircMetrics.Sidebar.urlFieldHeight / 2
        let top = fieldMid - AircMetrics.CommandBar.inputHeight / 2
        let width = min(AircMetrics.CommandBar.width - 125, bounds.width - x - 24)
        return NSRect(x: x, y: max(8, top), width: max(320, width), height: height)
    }

    /// ⌘T: centred in the whole window, as in Arc (the owner tried centring it over the page card and went back,
    /// 2026-11-06). ⌘L: over the URL field.
    func layoutIn(_ bounds: NSRect, sidebarFrame: NSRect, contentFrame: NSRect) {
        let placed = isParked ? bounds.offsetBy(dx: -(bounds.width + 4000), dy: 0) : bounds
        if frame != placed { frame = placed }
        self.sidebarFrame = sidebarFrame
        let content = contentFrame.isEmpty ? bounds : contentFrame
        self.contentFrame = content
        let rowsHeight = CGFloat(results.count) * AircMetrics.CommandBar.rowHeight + (results.isEmpty ? 0 : 12)
        let height = AircMetrics.CommandBar.inputHeight + rowsHeight
        let anchored = anchoredRect(in: bounds, height: height)
        if let r = anchored {
            panelRect = r
        } else {
            let width = min(AircMetrics.CommandBar.width, bounds.width - 80)
            let top = max(bounds.minY + 24, bounds.midY - AircMetrics.CommandBar.topAboveMiddle)
            panelRect = NSRect(x: (bounds.midX - width / 2).rounded(), y: top.rounded(), width: width, height: height)
        }
        let width = panelRect.width
        panel.frame = panelRect
        shadowView.frame = panelRect
        glass.frame = NSRect(x: 20, y: (AircMetrics.CommandBar.inputHeight - 24) / 2, width: 24, height: 24)
        // Over the URL field the text starts where the field's host did (12 pt in), so it doesn't jump (review #10).
        glass.isHidden = anchored != nil
        let inputX: CGFloat = anchored != nil ? AircAddressFieldLabel.leadingInset : 54
        chip.sizeToFit()
        let chipW = chip.isHidden ? 0 : chip.frame.width + 18
        chip.frame = NSRect(x: width - 16 - chipW + 9, y: (AircMetrics.CommandBar.inputHeight - chip.frame.height) / 2,
                            width: chipW - 18, height: chip.frame.height)
        input.frame = NSRect(x: inputX, y: (AircMetrics.CommandBar.inputHeight - 26) / 2, width: width - inputX - 20 - chipW, height: 26)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chipBackground.frame = NSRect(x: width - 16 - chipW, y: (AircMetrics.CommandBar.inputHeight - 24) / 2, width: chipW, height: 24)
        separator.isHidden = results.isEmpty
        separator.frame = NSRect(x: 0, y: AircMetrics.CommandBar.inputHeight - 0.5, width: width, height: 0.5)
        let shape = CGPath(roundedRect: shadowView.bounds, cornerWidth: AircMetrics.CommandBar.radius,
                           cornerHeight: AircMetrics.CommandBar.radius, transform: nil)
        shadowView.layer?.shadowPath = shape
        ambientShadow.frame = shadowView.bounds
        ambientShadow.shadowPath = shape
        CATransaction.commit()
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 6, y: AircMetrics.CommandBar.inputHeight + 6 + CGFloat(i) * AircMetrics.CommandBar.rowHeight,
                             width: width - 12, height: AircMetrics.CommandBar.rowHeight)
        }
    }

    // MARK: Typing and inline completion

    func controlTextDidChange(_ obj: Notification) {
        textDidChange(byDeleting: deletingEdit)
        deletingEdit = false
    }

    private func textDidChange(byDeleting deleting: Bool) {
        let text = input.stringValue
        typed = text
        update(allowCompletion: !deleting)
    }

    func update(allowCompletion: Bool = true) {
        guard let c = host else { return }
        let q = typed
        // History is searched off the main thread (H5). Until its answer arrives, the previous matches that still match
        // keep their rows, so typing on doesn't make them jump.
        historyHits = historyHits.filter { h in
            CommandSearch.score(q, in: h.entry.title) != nil || CommandSearch.score(q, in: URLRules.displayURL(h.entry.url)) != nil
        }
        // Yours first (history, open tabs, pinned items); a well-known site only when nothing of yours completes it.
        var site: CommonSites.Site?
        inline = Perf.time("cb.inline") { () -> InlineCompletion.Match? in
            guard allowCompletion && !isActionsMode else { return nil }
            if let m = c.inlineCompletion(for: q) { return m }
            guard let s = c.siteCompletion(for: q, history: historyHits) else { return nil }
            site = s.site
            return s.match
        }
        inlineSite = site
        if let editor = input.currentEditor() as? NSTextView {
            // The completion goes after the caret, selected so typing on replaces it (Chrome, Arc), drawn in the
            // theme's completion ink on its highlight, never the system selection colour (design §7, review #8).
            let r = palette.resolved
            editor.selectedTextAttributes = inline == nil ? r.textSelectionAttributes : r.inlineCompletionAttributes
            if let m = inline {
                input.stringValue = m.text
                let start = (q as NSString).length
                editor.selectedRange = NSRange(location: start, length: (m.text as NSString).length - start)
            }
        }
        let glyph = Symbols.image(isActionsMode ? "command" : "magnifyingglass", size: 17, weight: .medium)
        if glass.image !== glyph { glass.image = glyph }
        if suggestionQuery != q { suggestions = [] }
        results = Perf.time("cb.results") {
            c.commandResults(for: q, mode: mode, inline: inline, inlineSite: inlineSite, suggestions: suggestions, history: historyHits)
        }
        Perf.time("cb.rows") { reloadRows() }
        requestHistory(for: q)
        requestSuggestions(for: q)
    }

    private func requestHistory(for q: String) {
        guard let source = host?.commandBarHistory, !isActionsMode,
              !q.trimmingCharacters(in: .whitespaces).isEmpty else { historyHits = []; return }
        source.store.search(q, profileID: source.profileID, limit: 8) { [weak self] hits in
            MainActor.assumeIsolated {
                guard let self, let c = self.host, self.typed == q else { return }
                self.historyHits = hits
                let keep = self.selected
                self.results = c.commandResults(for: q, mode: self.mode, inline: self.inline, inlineSite: self.inlineSite,
                                                suggestions: self.suggestions, history: hits)
                self.reloadRows()
                self.select(min(keep, max(0, self.results.count - 1)))
                #if AIRC_TESTING
                self.onHistoryApplied?(hits.count)
                #endif
            }
        }
    }

    private func requestSuggestions(for q: String) {
        guard let c = host, !isActionsMode, URLRules.normalizeInput(q) == nil,
              q.trimmingCharacters(in: .whitespaces).count >= 2, let source = c.commandBarSuggestions else { return }
        SuggestionService.shared.fetch(q, engine: source.engine, profileID: source.profileID) { [weak self] list in
            guard let self, self.typed == q, !list.isEmpty else { return }
            self.suggestions = list
            self.suggestionQuery = q
            let keep = self.selected
            self.results = c.commandResults(for: q, mode: self.mode, inline: self.inline, inlineSite: self.inlineSite,
                                            suggestions: list, history: self.historyHits)
            self.reloadRows()
            self.select(min(keep, max(0, self.results.count - 1)))
        }
    }

    private func reloadRows() {
        selected = 0
        while rows.count < results.count { rows.append(makeRow()) }
        // Rows beyond the results stay, hidden, for the next keystroke or opening.
        for (i, r) in rows.enumerated() where r.isHidden != (i >= results.count) { r.isHidden = i >= results.count }
        Perf.time("cb.configure") { for (r, res) in zip(rows, results) { r.configure(res) } }
        Perf.time("cb.select") { select(0) }
        Perf.time("cb.layout") { if let sv = superview { layoutIn(sv.bounds, sidebarFrame: sidebarFrame, contentFrame: contentFrame) } }
    }

    private func select(_ i: Int) {
        selected = i
        for (j, r) in rows.enumerated() { r.isSelected = j == i }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if NSStringFromSelector(selector).hasPrefix("delete") { deletingEdit = true; return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !results.isEmpty { select((selected + 1) % results.count) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if !results.isEmpty { select((selected - 1 + results.count) % results.count) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            execute()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab on an empty field: actions (Arc). With an inline completion: accept it.
            if typed.isEmpty {
                input.stringValue = "/"
                textDidChange(byDeleting: false)
                return true
            }
            if inline != nil {
                textView.moveToEndOfDocument(nil)
                typed = input.stringValue
                update(allowCompletion: false)
                return true
            }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            if inline != nil {
                // First Esc drops the completion, the second closes.
                input.stringValue = typed
                inline = nil
                inlineSite = nil
                update(allowCompletion: false)
                return true
            }
            host?.closeCommandBar()
            return true
        default:
            return false
        }
    }

    private func execute() {
        guard results.indices.contains(selected) else { return }
        let r = results[selected]
        // Chosen: now its icon may come from the network (rows never ask for one while you type).
        CommandRowView.fetchIcon(of: r)
        host?.closeCommandBar()
        host?.performCommand(r.action, newTab: mode == .newTab, typed: true)
    }
}

/// AppKit's one-time text editing setup, done once per process off screen (see `CommandBarView.prewarmEditing`).
enum TextInputWarmup {
    private static var done = false

    static func run() {
        guard !done else { return }
        done = true
        let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 240, height: 40), styleMask: .borderless,
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.contentType = .URL   // as the bar's field: no password or one-time-code AutoFill heuristics
        w.contentView?.addSubview(field)
        w.makeFirstResponder(field)
        w.makeFirstResponder(nil)
        w.close()
    }
}

/// A built-in site's icon until its favicon arrives: the name's first letter on a calm colour picked from the name
/// (the same one every time), drawn once per site.
enum LetterTile {
    private static var made: [String: NSImage] = [:]
    private static let colors: [NSColor] = [
        NSColor(srgbRed: 0.36, green: 0.49, blue: 0.69, alpha: 1), NSColor(srgbRed: 0.31, green: 0.60, blue: 0.54, alpha: 1),
        NSColor(srgbRed: 0.54, green: 0.44, blue: 0.69, alpha: 1), NSColor(srgbRed: 0.75, green: 0.48, blue: 0.31, alpha: 1),
        NSColor(srgbRed: 0.43, green: 0.56, blue: 0.31, alpha: 1), NSColor(srgbRed: 0.69, green: 0.38, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.37, green: 0.56, blue: 0.66, alpha: 1), NSColor(srgbRed: 0.63, green: 0.54, blue: 0.31, alpha: 1),
    ]

    private static var warmed = false

    /// Loads the tiles' rounded font and draws one tile off the main thread, once per process: drawn cold on the main
    /// thread, the first tile took ~100 ms of a keystroke (cbperf, "gi").
    static func prewarm() {
        guard !warmed else { return }
        warmed = true
        DispatchQueue.global(qos: .utility).async {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            draw("Airc", in: NSRect(x: 0, y: 0, width: 36, height: 36))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func draw(_ name: String, in r: NSRect) {
        let letter = name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let size = r.height * 11 / 18
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white])
        colors[Int(h % UInt64(colors.count))].setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 4, yRadius: r.height / 4).fill()
        let t = text.size()
        text.draw(at: NSPoint(x: r.midX - t.width / 2, y: r.midY - t.height / 2 + r.height / 36))
    }

    static func image(for name: String) -> NSImage {
        if let hit = made[name] { return hit }
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            draw(name, in: r)
            return true
        }
        made[name] = img
        return img
    }
}

final class CommandRowView: NSView {
    var palette: Palette? { didSet { restyle() } }
    var isSelected = false { didSet { if isSelected != oldValue { restyle() } } }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private let icon = FaviconView()
    /// Built-in sites' icons get a view of their own: a favicon view keeps loading the last icon it was asked for, and a
    /// late one must not land on a row that has become a search row since (typing "sp" then "spot").
    private let siteIcon = FaviconView()
    /// A built-in site's letter tile, over its favicon until the icon arrives (a sublayer of `siteIcon`).
    private let tile = CALayer()
    private var tileKey: String?
    private var tileImage: NSImage?
    /// The icon a `.favicon` row asked the caches for, so a late answer for a reused row's earlier result is dropped.
    private var iconKey: String?
    private let emoji = NSTextField(labelWithString: "")
    private let title = AircFadingLabel(style: AircFont.row)
    private let subtitle = AircFadingLabel(style: AircFont.urlField)
    /// The selected row's action in the accent with its ↵ keycap (AircCommandActionView, review #9).
    private let action = AircCommandActionView(title: "", theme: DesignTheme.default.resolved(systemIsDark: false))
    /// An action's shortcut, one keycap per key.
    private var keycaps: [AircKeycapView] = []
    private var result: CommandResult?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        title.lineBreakMode = .byClipping
        subtitle.lineBreakMode = .byClipping
        emoji.font = NSFont.systemFont(ofSize: AircMetrics.Footer.spaceEmoji)
        emoji.alignment = .center
        for v in [icon, siteIcon, emoji, title, subtitle, action] as [NSView] { addSubview(v) }
        siteIcon.isHidden = true
        tile.actions = LayerImage.noActions
        tile.isHidden = true
        siteIcon.layer?.addSublayer(tile)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func configure(_ r: CommandResult) {
        result = r
        restyle()
    }

    /// What the labels show now: the bar is reused and reconfigured on every opening and keystroke, and setting the
    /// same text again would measure and redraw it (§2.12). Long titles and URLs are cut to what one line can show.
    private var shownTitle: NSAttributedString?
    private var shownSubtitle: NSAttributedString?
    private var shownTheme: ResolvedTheme?

    private func restyle() {
        guard let p = palette, let r = result else { return }
        let theme = p.resolved
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = isSelected ? p.panelSelection.cgColor : NSColor.clear.cgColor
        CATransaction.commit()
        var changed = false
        let titleText = TextLimits.clip(r.title)
        let t = NSMutableAttributedString(string: titleText, attributes: theme.commandRowTitleAttributes)
        let ns = titleText as NSString
        for m in r.matches where m < ns.length {
            t.addAttribute(.font, value: AircFont.row.weight(.semibold).appFont, range: NSRange(location: m, length: 1))
        }
        if shownTitle.map({ !$0.isEqual(to: t) }) ?? true {
            shownTitle = t
            title.attributedStringValue = t
            changed = true
        }
        let sub = NSAttributedString(string: TextLimits.clip(r.subtitle), attributes: theme.commandRowSubtitleAttributes)
        if shownSubtitle.map({ !$0.isEqual(to: sub) }) ?? true {
            shownSubtitle = sub
            subtitle.attributedStringValue = sub
            changed = true
        }
        if action.title != r.badge { action.title = r.badge; changed = true }
        let themeChanged = shownTheme != theme
        shownTheme = theme
        if themeChanged { action.theme = theme }
        let actionSelected = isSelected && !r.badge.isEmpty
        if action.isSelected != actionSelected { action.isSelected = actionSelected; changed = true }
        while keycaps.count < r.shortcut.count {
            let k = AircKeycapView("", theme: theme)
            addSubview(k)
            keycaps.append(k)
        }
        for (i, k) in keycaps.enumerated() {
            let hidden = i >= r.shortcut.count
            if k.isHidden != hidden { k.isHidden = hidden; changed = true }
            if i < r.shortcut.count, k.text != r.shortcut[i] { k.text = r.shortcut[i]; changed = true }
            if themeChanged { k.theme = theme }
        }
        if case .site = r.icon {} else {
            showTile(nil)
            if !siteIcon.isHidden { siteIcon.isHidden = true }
        }
        if case .favicon = r.icon {} else { iconKey = nil }
        // No row asks the network for an icon while you type, so the sites shown never learn what you might open: an
        // icon in memory or in the disk cache, or the placeholder (a letter tile for a built-in site) until the row is
        // chosen (`fetchIcon`).
        switch r.icon {
        case .favicon(let image, let url, let page):
            icon.isHidden = false
            emoji.isHidden = true
            let key = image == nil ? url ?? page.flatMap(FaviconCache.guess(for:)) : nil
            if let image {
                icon.set(image: image, url: nil, fallbackPage: nil, palette: p)
            } else if let img = FaviconCache.shared.cached(key) {
                icon.set(image: img, url: nil, fallbackPage: nil, palette: p)
            } else {
                icon.set(image: nil, url: nil, fallbackPage: nil, palette: p)
                if let key, iconKey != key {
                    iconKey = key
                    FaviconCache.shared.stored(key) { [weak self] img in
                        guard let self, self.iconKey == key, let img, let palette = self.palette else { return }
                        self.icon.set(image: img, url: nil, fallbackPage: nil, palette: palette)
                    }
                }
            }
            if key == nil || FaviconCache.shared.cached(key) != nil { iconKey = nil }
        case .site(let page, let name):
            icon.isHidden = true
            siteIcon.isHidden = false
            emoji.isHidden = true
            // The row asks the caches itself and hands the favicon view only finished images: the view's own request
            // isn't cleared by a cache hit, so a slower icon asked for by the row's previous site could land on this one
            // ("sp" shows Spiegel, "spot" Spotify). The letter tile shows until the icon is there.
            let key = FaviconCache.guess(for: page)
            if let img = FaviconCache.shared.cached(key) {
                siteIcon.set(image: img, url: nil, fallbackPage: nil, palette: p)
                showTile(nil)
            } else {
                siteIcon.set(image: nil, url: nil, fallbackPage: nil, palette: p)
                Perf.time("cb.tile") { showTile(LetterTile.image(for: name)) }
                if let key, tileKey != key {
                    tileKey = key
                    FaviconCache.shared.stored(key) { [weak self] img in
                        guard let self, self.tileKey == key, let img, let palette = self.palette else { return }
                        self.siteIcon.set(image: img, url: nil, fallbackPage: nil, palette: palette)
                        self.showTile(nil)
                    }
                }
            }
        case .symbol(let s):
            icon.isHidden = false
            emoji.isHidden = true
            icon.set(image: nil, url: nil, fallbackPage: nil, palette: p, symbol: s)
        case .emoji(let e):
            icon.isHidden = true
            emoji.isHidden = false
            if emoji.stringValue != e { emoji.stringValue = e }
        }
        if changed || themeChanged { needsLayout = true }
    }

    /// A chosen row's icon, from the network if no cache has it: the site is being opened now.
    static func fetchIcon(of r: CommandResult) {
        let key: String?
        switch r.icon {
        case .favicon(let image, let url, let page): key = image == nil ? url ?? page.flatMap(FaviconCache.guess(for:)) : nil
        case .site(let page, _): key = FaviconCache.guess(for: page)
        case .symbol, .emoji: key = nil
        }
        if let key, FaviconCache.shared.cached(key) == nil { FaviconCache.shared.load(key) { _ in } }
    }

    private func showTile(_ image: NSImage?) {
        if image == nil { tileKey = nil }
        if tile.isHidden != (image == nil) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tile.isHidden = image == nil
            CATransaction.commit()
        }
        if let image, image !== tileImage {
            tileImage = image
            LayerImage.set(image, on: tile, in: self)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let tileImage, LayerImage.scaleChanged(tile, in: self) { LayerImage.set(tileImage, on: tile, in: self) }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let m = AircMetrics.CommandBar.self
        icon.frame = NSRect(x: 14, y: (h - 18) / 2, width: 18, height: 18)
        siteIcon.frame = icon.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.frame = siteIcon.bounds
        CATransaction.commit()
        emoji.frame = NSRect(x: 11, y: (h - 20) / 2, width: 24, height: 20)
        // Trailing: the shortcut's keycaps, then (selected) the action and ↵ before them.
        var x = bounds.width - m.actionTrailing
        let shown = keycaps.filter { !$0.isHidden }
        for k in shown.reversed() {
            let w = AircKeycapView.size(for: k.text).width
            x -= w
            k.frame = NSRect(x: x, y: (h - m.keycapHeight) / 2, width: w, height: m.keycapHeight)
            x -= m.keycapGap
        }
        if !shown.isEmpty { x -= 10 - m.keycapGap }
        if !action.isHidden {
            let w = action.intrinsicContentSize.width
            x -= w
            action.frame = NSRect(x: x, y: (h - m.keycapHeight) / 2, width: w, height: m.keycapHeight)
        }
        let right = x - AircMetrics.Row.titleFadeGap
        let tw = min(title.fittingCellSize.width, (right - 46) * (subtitle.stringValue.isEmpty ? 1 : 0.62))
        title.frame = NSRect(x: 46, y: (h - 18) / 2, width: max(0, tw), height: 18)
        let sx = title.frame.maxX + 10
        subtitle.frame = NSRect(x: sx, y: (h - 16) / 2 + 1, width: max(0, right - sx), height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Results and actions

extension WindowController: CommandBarHost {
    var commandBarChip: String? {
        guard store.state.profiles.count > 1 else { return nil }
        let s = store.space(currentSpaceID)
        let p = store.profile(ofSpace: currentSpaceID)
        return [s.map(\.iconLabel), p.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var commandBarAnchorsToURLField: Bool { sidebarFraction >= 1 && revealController?.isRevealed != true }

    var commandBarHistory: (store: HistoryStore, profileID: String)? {
        app?.history.map { ($0, store.profile(ofSpace: currentSpaceID).id) }
    }

    var commandBarSuggestions: (engine: SearchEngine, profileID: String)? {
        guard app?.settings.values.suggestionsEnabled ?? true else { return nil }
        let profile = store.profile(ofSpace: currentSpaceID)
        return (profile.searchEngine, profile.id)
    }

    func openCommandBar(mode: CommandBarMode) {
        if let bar = commandBar {
            // ⌘T / ⌘L again closes it (Arc ref §5).
            let same = bar.mode == mode
            closeCommandBar()
            if same { return }
        }
        AppTelemetry.shared.commandBarOpened(mode)
        let bar = Perf.time("cb.open.make") { () -> CommandBarView in
            if let spare = spareCommandBar {
                spareCommandBar = nil
                spare.reuse(mode: mode, palette: currentPalette)
                return spare
            }
            return CommandBarView(mode: mode, palette: currentPalette, host: self)
        }
        commandBar = bar
        let profile = store.profile(ofSpace: currentSpaceID)
        app?.history.prepareIndex(profileID: profile.id)
        // The built-in sites' index, once per process, off the main thread (ready long before the first keystroke).
        CommonSitesIndex.shared.prepare()
        LetterTile.prewarm()
        if app?.settings.values.suggestionsEnabled ?? true {
            // After this frame's commit: the first opening per profile makes its URLSession here (milliseconds). Not
            // `async`: the main queue drains before the run loop's Core Animation commit, a 2 ms timer only after it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) {
                SuggestionService.shared.prewarm(engine: profile.searchEngine, profileID: profile.id)
            }
        }
        Perf.time("cb.open.add") {
            // A reused bar stays in the view tree, parked outside the window with its layers drawn; it only moves in
            // (and to the front).
            if bar.superview !== root || root.subviews.last !== bar { root.addSubview(bar) }
            bar.unpark()
            bar.layoutIn(root.bounds, sidebarFrame: sidebar.frame, contentFrame: card.frame)
        }
        if mode == .editURL, sidebarFraction >= 1, revealController?.isRevealed != true,
           let field = pageView(for: currentSpaceID)?.urlField, field.window != nil {
            bar.grow(from: field.convert(field.bounds, to: bar))
        }
        let current = mode == .editURL ? (engineTab(for: shownTabID ?? "")?.url?.absoluteString ?? currentTab?.url ?? "") : ""
        Perf.time("cb.open.focus") { bar.focus(with: URLRules.isNewTab(current) ? "" : current) }
        pageView(for: currentSpaceID)?.refreshNewTabRow()
    }

    func closeCommandBar() {
        guard let bar = commandBar else { return }
        commandBar = nil
        // A New Split View waiting for a pick: the pick (performCommand) comes right after this, in the same turn; a bar
        // closed without one (Esc, a click elsewhere) drops it.
        if let token = pendingSplit?.token {
            DispatchQueue.main.async { [weak self] in if self?.pendingSplit?.token == token { self?.pendingSplit = nil } }
        }
        // Kept for the next opening, hidden (its field gives up the keyboard first).
        if let editor = window.firstResponder as? NSView, editor === bar || editor.isDescendant(of: bar) {
            window.makeFirstResponder(nil)
        }
        bar.park()
        spareCommandBar = bar
        scheduleSpareBarRefresh()
        if let id = shownTabID { engineTab(for: id)?.focus() }
        // Every page: a Space switch closes the bar after the current Space changed.
        for spaceID in store.orderedSpaces.map(\.id) { pageView(for: spaceID)?.refreshNewTabRow() }
    }

    func isCommandBarOpen(mode: CommandBarMode) -> Bool { commandBar?.mode == mode }

    /// The parked bar shows what ⌘T will (CommandBarView.prepareForNextOpening): set a moment after whatever changes
    /// it (a tab shown or closed, a title or icon, a Space switch, the window's size, the bar closing), when nothing is
    /// moving, so its rows are drawn in an idle frame rather than in ⌘T's (§2.12).
    func scheduleSpareBarRefresh() {
        guard !spareRefreshScheduled, spareCommandBar != nil else { return }
        spareRefreshScheduled = true
        // A timer, not `async`: the main queue drains before the run loop's commit, and this belongs in a frame of its own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.spareRefreshScheduled = false
            guard let bar = self.spareCommandBar, self.commandBar == nil, bar.superview === self.root else { return }
            if self.isBusyForIdleWork { return self.scheduleSpareBarRefresh() }
            bar.prepareForNextOpening(palette: self.currentPalette, in: self.root.bounds, sidebarFrame: self.sidebar.frame,
                                      contentFrame: self.card.frame)
        }
    }

    func performCommand(_ action: CommandResult.Action, newTab: Bool, typed: Bool = false) {
        // SV-1: ⌃⇧+ opened the bar for a new pane.
        if newTab, performSplitPick(action, typed: typed) { return }
        switch action {
        case .open(let url):
            navigate(to: url, newTab: newTab, typed: typed)
        case .tab(let id):
            guard let t = store.tab(id) else { return }
            if let sid = t.spaceID, sid != currentSpaceID { switchToSpace(sid, animated: true) }
            show(id)
        case .item(let id):
            guard let item = store.item(id) else { return }
            if let sid = item.spaceID, sid != currentSpaceID { switchToSpace(sid, animated: true) }
            activate(entry: item.isFavorite ? .favorite(item, store.liveTab(forItem: id)) : .pinned(item, depth: 0, store.liveTab(forItem: id)))
        case .space(let id):
            switchToSpace(id, animated: true)
        case .run(let block):
            block()
        }
    }

    /// Inline completion (Chrome, Arc) from this profile's history, open tabs, pinned items and Favorites. History comes
    /// from its index: a binary search in sorted keys, no scan on the main thread (H5).
    func inlineCompletion(for typed: String) -> InlineCompletion.Match? {
        guard !typed.isEmpty, !typed.hasPrefix("/") else { return nil }
        let profile = store.profile(ofSpace: currentSpaceID)
        var candidates: [(url: String, weight: Double)] = []
        for t in store.state.tabs.values where t.profileID == profile.id { candidates.append((t.url, 1)) }
        for i in store.state.items.values where i.kind == .tab {
            let mine = i.profileID == profile.id || (i.spaceID.map { store.space($0)?.profileID == profile.id } ?? false)
            if mine, let u = i.savedURL { candidates.append((u, 2)) }
        }
        if let index = app?.history.indexSnapshot(profileID: profile.id) {
            return index.inlineCompletion(for: typed, extra: candidates)
        }
        return InlineCompletion.complete(typed, candidates: candidates)
    }

    /// The region the built-in sites are ranked for (this Mac's).
    static let siteRegion = CommonSites.currentRegion

    /// The built-in sites' index once it's built. Test builds can leave the list out (`AIRC_COMMON_SITES=0`), to
    /// measure the Command Bar with and without it in one binary.
    static var commonSites: CommonSitesSnapshot? {
        #if AIRC_TESTING
        if sitesDisabled { return nil }
        #endif
        return CommonSitesIndex.shared.snapshot
    }
    #if AIRC_TESTING
    private static let sitesDisabled = ProcessInfo.processInfo.environment["AIRC_COMMON_SITES"] == "0"
    #endif

    /// Inline completion from the built-in sites (CommonSites), when `inlineCompletion(for:)` found nothing of yours:
    /// "spot" → "spotify.com". Not for a site you already have (open, pinned, a Favorite or in this profile's history:
    /// your own rows show it), nor over a page of yours whose title matches as well. nil until the list's index is
    /// built (the first ⌘T starts it). Binary searches and a pass over this profile's tabs: main-thread cheap.
    func siteCompletion(for typed: String, history: [HistoryMatch]) -> CommonSites.Completion? {
        guard !typed.hasPrefix("/"), let index = Self.commonSites,
              let s = index.inlineCompletion(for: typed, region: Self.siteRegion) else { return nil }
        let profile = store.profile(ofSpace: currentSpaceID)
        if let h = app?.history.indexSnapshot(profileID: profile.id), s.site.keyHosts.contains(where: h.hasHost) { return nil }
        var pages: [(url: String, title: String)] = history.map { ($0.entry.url, $0.entry.title) }
        for t in store.state.tabs.values where t.profileID == profile.id {
            pages.append((t.url, engineTab(for: t.id)?.title ?? t.displayTitle))
        }
        for i in store.state.items.values where i.kind == .tab {
            let mine = i.profileID == profile.id || (i.spaceID.map { store.space($0)?.profileID == profile.id } ?? false)
            if mine, let u = i.savedURL { pages.append((u, i.displayTitle)) }
        }
        for p in pages {
            if s.site.covers(url: p.url) { return nil }
            if let m = CommandSearch.score(typed, in: p.title), m.score + CommandSearch.siteMargin >= 100 { return nil }
        }
        return s
    }

    /// A built-in site's row.
    private func siteResult(_ site: CommonSites.Site, matches: [Int]) -> CommandResult? {
        guard let url = URL(string: site.url) else { return nil }
        return CommandResult(title: site.name, subtitle: URLRules.displayURL(site.url), badge: "Open",
                             icon: .site(page: site.url, name: site.name), matches: matches, action: .open(url))
    }

    /// Open tabs, pinned items, Favorites and history of the current profile (SP-24), Spaces, commands, the search row
    /// and the profile's search suggestions. "/…" lists only actions.
    func commandResults(for query: String, mode: CommandBarMode, inline: InlineCompletion.Match? = nil,
                        inlineSite: CommonSites.Site? = nil, suggestions: [String] = [],
                        history: [HistoryMatch] = []) -> [CommandResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let profile = store.profile(ofSpace: currentSpaceID)

        // "/" (or Tab on an empty field): actions only.
        if q.hasPrefix("/") {
            let rest = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            let actions = commandActions()
            let candidates = actions.enumerated().map { i, a in
                CommandSearch.Candidate(id: "\(i)", kind: .action, title: a.title, keywords: a.keywords, boost: -Double(i) * 0.01)
            }
            return CommandSearch.rank(rest, candidates, limit: AircMetrics.CommandBar.maxRows).compactMap { r in
                guard let i = Int(r.candidate.id) else { return nil }
                let a = actions[i]
                return CommandResult(title: a.title, subtitle: "", badge: "Run", icon: .symbol(a.symbol),
                                     matches: r.titleMatches, action: .run(a.run), shortcut: CommandResult.keys(of: a.hint))
            }
        }

        var candidates: [CommandSearch.Candidate] = []
        var actions: [String: CommandResult] = [:]
        var urls = Set<String>()
        let now = Date()

        func addTab(_ t: LiveTab) {
            guard t.id != shownTabID else { return }
            let page = engineTab(for: t.id)
            let title = page?.title.isEmpty == false ? page!.title : t.displayTitle
            let id = "tab:" + t.id
            let recency = max(0, 3 - now.timeIntervalSince(t.lastActiveAt) / 3600)
            candidates.append(.init(id: id, kind: .openTab, title: title, subtitle: URLRules.displayURL(t.url), boost: recency))
            actions[id] = CommandResult(title: title, subtitle: URLRules.displayHost(t.url), badge: "Switch to Tab",
                                        icon: .favicon(image: page?.favicon, url: t.faviconURL, page: t.url), matches: [],
                                        action: .tab(t.id))
            urls.insert(t.url)
        }
        for t in store.state.tabs.values where t.profileID == profile.id && t.itemID == nil { addTab(t) }
        // An empty query only shows recent Today tabs. Avoid constructing pinned, Space and action
        // candidates (including their icons and shortcuts) that the empty-query branch discards.
        var recentOnly = q.isEmpty
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_COMMAND_BASELINE"] == "1" { recentOnly = false }
        #endif
        if recentOnly {
            let recent = CommandSearch.rank("", candidates, limit: 6)
            return recent.compactMap { actions[$0.candidate.id] }
        }
        for item in store.state.items.values where item.kind == .tab {
            let inProfile = item.profileID == profile.id || (item.spaceID.map { store.space($0)?.profileID == profile.id } ?? false)
            guard inProfile, let saved = item.savedURL else { continue }
            let live = store.liveTab(forItem: item.id)
            if live?.id == shownTabID { continue }
            let id = "item:" + item.id
            candidates.append(.init(id: id, kind: item.isFavorite ? .favorite : .pinned, title: item.displayTitle,
                                    subtitle: URLRules.displayURL(saved)))
            actions[id] = CommandResult(title: item.displayTitle, subtitle: URLRules.displayHost(saved),
                                        badge: item.isFavorite ? "Favorite" : "Pinned",
                                        icon: .favicon(image: live.flatMap { engineTab(for: $0.id)?.favicon },
                                                       url: item.faviconURL, page: saved),
                                        matches: [], action: .item(item.id))
            urls.insert(saved)
        }
        for s in store.orderedSpaces where s.id != currentSpaceID {
            let id = "space:" + s.id
            candidates.append(.init(id: id, kind: .space, title: s.name, subtitle: "Space", keywords: ["space"]))
            actions[id] = CommandResult(title: s.name, subtitle: "Switch to Space", badge: "Space",
                                        icon: .emoji(s.iconLabel), matches: [], action: .space(s.id))
        }
        for a in commandActions() {
            let id = "action:" + a.title
            candidates.append(.init(id: id, kind: .action, title: a.title, keywords: a.keywords))
            actions[id] = CommandResult(title: a.title, subtitle: "", badge: "Run", icon: .symbol(a.symbol),
                                        matches: [], action: .run(a.run), shortcut: CommandResult.keys(of: a.hint))
        }

        if q.isEmpty {
            // ⌘T on its own: the most recent tabs of this profile first.
            let recent = CommandSearch.rank("", candidates.filter { $0.kind == .openTab }, limit: 6)
            return recent.compactMap { actions[$0.candidate.id] }
        }

        // History (this profile only, searched off the main thread), ranked by match and frecency; pages that are open
        // or pinned show once, as the tab. A built-in site's completion is its home page: the same page from history
        // doesn't show again under it.
        let siteHome = inlineSite.map { URLRules.displayURL($0.url) }
        do {
            for (i, r) in history.enumerated() where !urls.contains(r.entry.url) && r.entry.url != inline?.url
                && URLRules.displayURL(r.entry.url) != siteHome {
                let id = "history:\(i)"
                let title = r.entry.title.isEmpty ? URLRules.displayURL(r.entry.url) : r.entry.title
                // History scores already include the match; boost so a page you live on outranks a weak tab match.
                candidates.append(.init(id: id, kind: .history, title: title, subtitle: URLRules.displayURL(r.entry.url),
                                        boost: min(12, 4 * log2(1 + r.entry.frecency(now: now)))))
                actions[id] = CommandResult(title: title, subtitle: URLRules.displayHost(r.entry.url), badge: "Open",
                                            icon: .favicon(image: nil, url: nil, page: r.entry.url), matches: [],
                                            action: .open(URL(string: r.entry.url)!))
            }
        }

        // Well-known sites (CommonSites) you have never been to, below every result of yours that matches as well, one
        // or two of them (more for a site's exact name); not the one already completed inline, nor the address typed.
        let personal = CommandSearch.rank(q, candidates, limit: 7)
        var sites: [CommonSites.Match] = []
        if let index = Self.commonSites {
            let typedURL = URLRules.normalizeInput(q)
            sites = Perf.time("cb.sites") {
                index.search(q, region: Self.siteRegion, limit: CommandSearch.maxSitesForName + 1).filter { m in
                    m.site != inlineSite && !(typedURL.map { m.site.covers(url: $0) } ?? false)
                }
            }
        }
        let blended = CommandSearch.blend(personal, sites: sites,
                                          personalURLs: Array(urls) + history.map(\.entry.url) + [inline?.url].compactMap { $0 },
                                          limit: 7)
        var out: [CommandResult] = []
        var ranked = blended.compactMap { b -> CommandResult? in
            switch b {
            case .personal(let r):
                guard var res = actions[r.candidate.id] else { return nil }
                res.matches = r.titleMatches
                return res
            case .site(let m):
                return siteResult(m.site, matches: m.matches)
            }
        }
        // The best row goes above the search row when it's clearly what was meant: one of yours that matches strongly,
        // or a site by its exact name or alias ("yt") or the start of a name of several words ("google cal").
        let strong: Bool = switch blended.first {
        case .personal(let r): r.score >= 85
        case .site(let m): m.isExact || (q.contains(" ") && m.score >= 95)
        case nil: false
        }
        let search = { (text: String, subtitle: String) in
            CommandResult(title: text, subtitle: subtitle, badge: "Search", icon: .symbol("magnifyingglass"), matches: [],
                          action: .open(profile.searchEngine.searchURL(for: text)))
        }
        if inline != nil, let site = inlineSite,
           let row = siteResult(site, matches: CommandSearch.score(q, in: site.name)?.matches ?? []) {
            // A built-in site completed inline: its row first, by name ("Spotify  open.spotify.com").
            out.append(row)
            out.append(search(q, AircCommandText.searchSubtitle(engine: profile.searchEngine.name)))
        } else if let m = inline, let url = URL(string: m.url) {
            // The completed address first: Enter opens what the field shows.
            out.append(CommandResult(title: m.text, subtitle: "", badge: "Open",
                                     icon: .favicon(image: nil, url: nil, page: m.url), matches: Array(0..<m.typedCount), action: .open(url)))
            out.append(search(q, AircCommandText.searchSubtitle(engine: profile.searchEngine.name)))
        } else if let u = URLRules.normalizeInput(q), let url = URL(string: u) {
            out.append(CommandResult(title: q, subtitle: "", badge: "Open", icon: .favicon(image: nil, url: nil, page: u),
                                     matches: [], action: .open(url)))
        } else {
            if strong, !ranked.isEmpty { out.append(ranked.removeFirst()) }
            out.append(search(q, AircCommandText.searchSubtitle(engine: profile.searchEngine.name)))
        }
        // A few top hits, then the engine's suggestions, then the rest.
        out += ranked.prefix(3)
        ranked.removeFirst(min(3, ranked.count))
        for sug in suggestions.prefix(3) where sug.lowercased() != q.lowercased() {
            out.append(search(sug, ""))
        }
        out += ranked
        return Array(out.prefix(AircMetrics.CommandBar.maxRows))
    }

    struct CommandAction {
        var title: String
        var symbol: String
        var hint: String
        var keywords: [String]
        var run: () -> Void
    }

    func commandActions() -> [CommandAction] {
        var a: [CommandAction] = [
            .init(title: "New Space…", symbol: "plus.square.on.square", hint: "", keywords: ["space", "create"]) { [weak self] in self?.openNewSpacePanel() },
            .init(title: "New Folder", symbol: "folder.badge.plus", hint: "", keywords: ["folder"]) { [weak self] in
                guard let self else { return }
                _ = try? self.store.createFolder(inSpace: self.currentSpaceID)
            },
            .init(title: sidebarHidden ? "Show Sidebar" : "Hide Sidebar", symbol: "sidebar.left", hint: "⌘S", keywords: ["toggle"]) { [weak self] in self?.toggleSidebar() },
            .init(title: "Edit Theme Color…", symbol: "paintpalette", hint: "", keywords: ["theme", "colour", "color"]) { [weak self] in
                guard let self else { return }
                self.editTheme(self.currentSpaceID)
            },
            .init(title: "Rename Space…", symbol: "pencil", hint: "", keywords: ["space"]) { [weak self] in self?.renameCurrentSpace() },
            .init(title: "Clear Today", symbol: "arrow.down.to.line", hint: "⇧⌘K", keywords: ["archive", "clean"]) { [weak self] in self?.clearToday() },
            .init(title: "Library", symbol: "archivebox", hint: "⇧⌘L", keywords: ["archive", "history"]) { [weak self] in self?.showLibrary() },
        ]
        if currentTab != nil {
            a.append(.init(title: "Add Split View", symbol: "rectangle.split.2x1", hint: "⌃⇧+", keywords: ["split", "side", "pane"]) { [weak self] in
                self?.newSplitView()
            })
        }
        if shownSplitID != nil {
            a.append(.init(title: "Separate All Tabs", symbol: "rectangle.split.2x1.slash", hint: "", keywords: ["split", "unsplit"]) { [weak self] in
                self?.separateShownSplit()
            })
        }
        if let t = currentTab {
            a += [
                .init(title: t.isToday ? "Pin Tab" : "Unpin Tab", symbol: "pin", hint: "⌘D", keywords: ["bookmark"]) { [weak self] in self?.togglePin() },
                .init(title: "Add to Favorites", symbol: "star", hint: "", keywords: ["favorite", "favourite"]) { [weak self] in self?.addCurrentToFavorites() },
                .init(title: "Copy URL", symbol: "link", hint: "⇧⌘C", keywords: ["link"]) { [weak self] in self?.copyURL() },
                .init(title: "Copy URL as Markdown", symbol: "text.badge.plus", hint: "⌥⇧⌘C", keywords: ["link"]) { [weak self] in self?.copyURLMarkdown() },
                .init(title: "Reload", symbol: "arrow.clockwise", hint: "⌘R", keywords: ["refresh"]) { [weak self] in self?.reloadOrStop() },
                .init(title: "Duplicate Tab", symbol: "plus.square.on.square", hint: "", keywords: ["copy"]) { [weak self] in
                    guard let self, let id = self.shownTabID else { return }
                    _ = try? self.store.duplicateTab(id)
                },
            ]
            if !t.isToday && store.isDrifted(t.id) {
                a.append(.init(title: "Reset Tab", symbol: "arrow.uturn.backward", hint: "", keywords: ["pinned"]) { [weak self] in
                    self?.resetToSaved(t.id, keepCurrent: false)
                })
            }
            for s in store.orderedSpaces where s.id != currentSpaceID && t.isToday {
                a.append(.init(title: "Move Tab to \(s.name)", symbol: "arrow.right.square", hint: "", keywords: ["space"]) { [weak self] in
                    self?.moveTab(t.id, to: s.id)
                })
            }
        }
        return a
    }
}
