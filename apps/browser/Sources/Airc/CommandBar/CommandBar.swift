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

/// What the bar searches while a scope's pill leads the field (Arc's Site Search: "yt", Tab, then the query). Return
/// searches the scope instead of the profile's engine, Backspace on an empty query or Esc leaves it. One kind today; a
/// new kind (a ChatGPT prompt, package P07b) adds a case with its own name, placeholder and `results(for:)`.
enum CommandBarScope: Equatable {
    case site(SiteSearch)

    var name: String {
        switch self {
        case .site(let s): s.name
        }
    }

    /// Arc's "Site Search placeholder where the wildcard is the name of the site".
    var placeholder: String { "Search \(name)…" }
}

/// A window's site searches for its bar: its profile's (Settings → Site Search), and whether Space starts one too.
struct CommandBarSiteSearches {
    var index: SiteSearchIndex
    var spaceTriggers: Bool

    /// Rebuilt only when the profile's list changes; asked on every keystroke.
    private static var cache: [String: SiteSearchIndex] = [:]

    static func of(_ settings: SiteSearchSettings, profileID: String) -> CommandBarSiteSearches {
        let list = settings.searches(for: profileID)
        let index: SiteSearchIndex
        if let hit = cache[profileID], hit.searches == list {
            index = hit
        } else {
            index = SiteSearchIndex(list)
            cache[profileID] = index
        }
        return CommandBarSiteSearches(index: index, spaceTriggers: settings.spaceTriggers(for: profileID))
    }
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
    /// Stable across asynchronous ranking changes; labels and row positions are not identity.
    enum SelectionID: Equatable {
        case open(URL, kind: String), tab(String), item(String), space(String), command(String)
    }
    var selectionID: SelectionID {
        switch action {
        case .open(let url): return .open(url, kind: historyURL == nil ? badge : "history")
        case .tab(let id): return .tab(id)
        case .item(let id): return .item(id)
        case .space(let id): return .space(id)
        case .run: return .command(title)
        }
    }
    /// An action's shortcut as keycaps ("⇧", "⌘", "C"), shown on its row (design.md §7 "Command bar").
    var shortcut: [String] = []
    /// Only a history suggestion can be removed. Tabs, commands and search rows never carry this.
    var historyURL: String?
    /// The "Search YouTube" row: choosing it (Return, a click) starts that site's search instead of running `action`.
    var startsScope: CommandBarScope?

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
    /// This window's site searches (its profile's); nil: none.
    var commandBarSiteSearches: CommandBarSiteSearches? { get }
    /// Whether rows may show (and, once chosen, fetch) site icons; a private window's never do.
    var commandBarShowsSiteIcons: Bool { get }
}

extension CommandBarHost {
    var commandBarSiteSearches: CommandBarSiteSearches? { nil }
    var commandBarShowsSiteIcons: Bool { true }
}

/// A private window searches its profile's sites too (as Chrome's incognito keeps its profile's search engines), with
/// letter tiles for icons: nothing is fetched or cached for it.
extension PrivateWindowController {
    var commandBarSiteSearches: CommandBarSiteSearches? {
        app.map { CommandBarSiteSearches.of($0.settings.values.siteSearch, profileID: profileID) }
    }
    var commandBarShowsSiteIcons: Bool { false }
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
    private let input = CommandBarInputField()
    /// The edit in progress deletes text: don't complete it again (backspace over a completion removes it).
    private var deletingEdit = false
    private let glass = NSImageView()
    private let chip = NSTextField(labelWithString: "")
    private let chipBackground = CALayer()
    private let separator = CALayer()
    private var rows: [CommandRowView] = []
    private(set) var results: [CommandResult] = []
    private(set) var selected = 0
    private var selectedHistoryURL: String?
    private var userSelectedResult: CommandResult.SelectionID?
    private(set) var panelRect = NSRect.zero
    private var sidebarFrame = NSRect.zero
    private var contentFrame = NSRect.zero
    /// What the user actually typed (the field may also hold a selected inline completion).
    private(set) var typed = ""
    private var suggestions: [String] = []
    private var suggestionQuery = ""
    /// The last history matches (searched off the main thread, H5) and the query they were for.
    private var historyHits: [HistoryMatch] = []
    private var removedHistory = Set<String>()
    #if AIRC_TESTING
    /// Debug hook: history matches were applied to the rows (`--script cbperf`).
    var onHistoryApplied: ((Int) -> Void)?
    /// What reached the bar from the keyboard, in order ("insertTab:", "text", "suggestionKey"): proof that a posted
    /// key was delivered (`--script parityp07`).
    var keyLog: [String] = []
    #endif
    /// The inline completion shown after the caret, if any.
    private(set) var inline: InlineCompletion.Match?
    /// The built-in site the inline completion came from, when nothing of yours completed what was typed.
    private(set) var inlineSite: CommonSites.Site?
    /// Site Search: the scope the field searches now, shown as a pill before the text; nil for the plain bar.
    private(set) var scope: CommandBarScope?
    /// What was typed before the scope began ("yt"): leaving it with Backspace puts it back.
    private var scopeOrigin = ""
    /// The site Tab would search for what's typed (its "Search YouTube" row is shown).
    private(set) var siteCandidate: SiteSearch?
    private let scopePill = CommandBarScopePill()

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
        scopePill.isHidden = true
        scopePill.onMenu = { [weak self] in self?.scopeMenu() }
        panel.addSubview(scopePill)
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
        removedHistory = []
        deletingEdit = false
        siteCandidate = nil
        scopeOrigin = ""
        if scope != nil {
            scope = nil
            applyScope()
        }
        if !input.stringValue.isEmpty { input.stringValue = "" }
        // Restyling with the same palette re-set every row and the field, which then measured and redrew (§2.12).
        if self.palette != palette { self.palette = palette } else { updateChip() }
    }

    /// Between openings the bar stays in the view tree. Its backing layer is parked outside the window while
    /// AppKit keeps drawing the view's current contents at idle, including before the first opening. Parked, it
    /// takes no clicks, hover, cursor or keyboard and has no accessibility children; `prepareForNextOpening`
    /// keeps its rows what ⌘T will show.
    private(set) var isParked = false

    // One binary for interleaved, fresh-process comparisons. Public builds always park the layer.
    private static let parksLayer: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_COMMAND_BASELINE"] != "1"
        #else
        return true
        #endif
    }()

    func park() {
        isParked = true
        // A parked bar's rows aren't under the pointer, whatever their tracking areas last heard.
        for r in rows { r.clearHover() }
        input.refusesFirstResponder = true
        if Self.parksLayer {
            input.isParked = true
            window?.invalidateCursorRects(for: input)
        }
        if let sv = superview { layoutIn(sv.bounds, sidebarFrame: sidebarFrame, contentFrame: contentFrame) }
    }

    func unpark() {
        isParked = false
        input.refusesFirstResponder = false
        if Self.parksLayer {
            input.isParked = false
            window?.invalidateCursorRects(for: input)
        }
    }

    /// At idle, while parked: what ⌘T will show (this Space's chip and palette, the profile's recent tabs, the window's
    /// size), set now so Core Animation draws it in an idle frame, and the opening only moves the bar in and focuses it.
    func prepareForNextOpening(palette: Palette, in bounds: NSRect, sidebarFrame: NSRect, contentFrame: NSRect) {
        guard isParked else { return }
        if Self.localHistoryEnabled, let source = host?.commandBarHistory { source.store.prepareLocalIndex(profileID: source.profileID) }
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
        r.onRemove = { [weak self, weak r] in
            guard let self, !self.isParked, let r, let i = self.rows.firstIndex(where: { $0 === r }) else { return }
            self.removeHistorySuggestion(at: i)
            // The keyboard stays in the field (the ✕ never takes it).
            if self.window?.firstResponder !== self.input.currentEditor() { self.window?.makeFirstResponder(self.input) }
        }
        r.onHover = { [weak self, weak r] in
            guard let self, !self.isParked, let r, let i = self.rows.firstIndex(where: { $0 === r }), i < self.results.count else { return }
            self.select(i, userMoved: true)
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
    /// "/…" lists actions, except as a site search's query ("/r/swift" on Reddit).
    var isActionsMode: Bool { scope == nil && typed.hasPrefix("/") }
    /// An input method is composing (Japanese, Chinese): the field's marked text is the input method's, so nothing
    /// completes, replaces or selects text and no key starts a scope until it's committed.
    var isComposing: Bool { (input.currentEditor() as? NSTextView)?.hasMarkedText() == true }
    /// The field's text, marked text included (checks).
    var fieldText: String { input.stringValue }
    /// The rows on screen, top to bottom (checks: the hover ✕).
    var visibleRows: [CommandRowView] { Array(rows.prefix(results.count)) }
    /// What the empty field shows ("Search YouTube…"); setting the attributed placeholder clears the plain one.
    var placeholderText: String { input.placeholderAttributedString?.string ?? input.placeholderString ?? "" }

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
        applyPlaceholder()
        scopePill.palette = palette
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

    private func applyPlaceholder() {
        let text = scope?.placeholder ?? "Search or Enter URL…"
        input.placeholderString = text
        input.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .foregroundColor: palette.panelSecondary, .font: AircFont.commandInput.appFont])
    }

    // MARK: Site Search

    /// The pill, placeholder and glyph for the current scope (none: the plain bar).
    private func applyScope() {
        if case .site(let s)? = scope {
            scopePill.show(s, icons: host?.commandBarShowsSiteIcons ?? false)
        }
        if scopePill.isHidden != (scope == nil) { scopePill.isHidden = scope == nil }
        applyPlaceholder()
        input.setAccessibilityLabel(scope.map { "Search \($0.name)" })
        if let sv = superview { layoutIn(sv.bounds, sidebarFrame: sidebarFrame, contentFrame: contentFrame) }
    }

    /// Tab (or Space after a shortcut, or the "Search YouTube" row): the field empties, the site's pill leads it and
    /// Return searches the site. `origin` is what Backspace on the empty query puts back (what was typed).
    func enterScope(_ s: CommandBarScope, origin: String? = nil) {
        guard !isComposing else { return }
        scopeOrigin = origin ?? typed
        scope = s
        inline = nil
        inlineSite = nil
        siteCandidate = nil
        suggestions = []
        suggestionQuery = ""
        typed = ""
        input.stringValue = ""
        applyScope()
        if case .site(let site) = s, host?.commandBarShowsSiteIcons == true { scopePill.fetchIcon(site) }
        update(allowCompletion: false)
        NSAccessibility.post(element: input, notification: .announcementRequested,
                             userInfo: [.announcement: "Searching \(s.name)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Back to the plain bar. Backspace and Esc put back what was typed before the scope ("yt"), then the query if there
    /// was one, the caret after "yt " (as Chrome's keyword mode); a profile switch that drops the site keeps the query.
    func leaveScope(restoring: Bool = true) {
        guard scope != nil else { return }
        let query = typed
        scope = nil
        applyScope()
        let text = !restoring ? query : query.isEmpty ? scopeOrigin : scopeOrigin + " " + query
        let caret = !restoring ? (text as NSString).length : (scopeOrigin as NSString).length + (query.isEmpty ? 0 : 1)
        scopeOrigin = ""
        typed = text
        input.stringValue = text
        if let editor = input.currentEditor() as? NSTextView { editor.selectedRange = NSRange(location: caret, length: 0) }
        update(allowCompletion: false)
    }

    /// A click on the pill: Arc's menu. Change Site Search › every site, Remove “…” Site Search (leaves it), Manage.
    private func scopeMenu() {
        guard case .site(let current)? = scope else { return }
        let menu = NSMenu()
        let change = NSMenuItem(title: "Change Site Search", action: nil, keyEquivalent: "")
        let sites = NSMenu()
        for s in host?.commandBarSiteSearches?.index.searches ?? [] {
            sites.add(s.name) { [weak self] in
                guard let self, self.scope != nil else { return }
                self.scope = .site(s)
                self.applyScope()
                if self.host?.commandBarShowsSiteIcons == true { self.scopePill.fetchIcon(s) }
                self.update(allowCompletion: false)
            }.state = s.id == current.id ? .on : .off
        }
        change.submenu = sites
        menu.addItem(change)
        menu.add("Remove \(current.name) Site Search") { [weak self] in self?.leaveScope(restoring: false) }
        menu.addItem(.separator())
        menu.add("Manage Site Searches…") { [weak self] in
            self?.host?.closeCommandBar()
            (NSApp.delegate as? AppDelegate)?.showSettings(page: .siteSearch)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: scopePill.bounds.maxY + 4), in: scopePill)
    }

    #if AIRC_TESTING
    /// The pill's menu titles (checks): the menu itself is modal.
    var scopeMenuTitles: [String] {
        guard case .site(let current)? = scope else { return [] }
        return ["Change Site Search", "Remove \(current.name) Site Search", "Manage Site Searches…"]
    }
    var scopePillFrame: NSRect { scopePill.isHidden ? .zero : scopePill.convert(scopePill.bounds, to: self) }
    var inputFrame: NSRect { input.convert(input.bounds, to: self) }
    #endif

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
        if isParked { return nil }
        let p = convert(point, from: superview)
        if sidebarFrame.contains(p) && !panelRect.contains(p) { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panelRect.contains(p) { host?.closeCommandBar() }
    }

    /// Over the URL field (⌘L, click) when the sidebar is docked; centred otherwise (⌘T, hidden sidebar). Its left edge
    /// is the field's and its input row is centred on the field, so it reads as the field growing (Arc ref §2.2). With
    /// the sidebar on the right (WIN-5) its right edge is the field's: it grows over the page, to the left.
    private func anchoredRect(in bounds: NSRect, height: CGFloat) -> NSRect? {
        guard mode == .editURL, host?.commandBarAnchorsToURLField == true else { return nil }
        let fieldMid = AircMetrics.Sidebar.urlFieldTop + AircMetrics.Sidebar.urlFieldHeight / 2
        let top = fieldMid - AircMetrics.CommandBar.inputHeight / 2
        if sidebarFrame.midX > bounds.midX {
            let right = sidebarFrame.maxX - AircMetrics.Sidebar.inset
            let width = max(320, min(AircMetrics.CommandBar.width - 125, right - 24))
            return NSRect(x: right - width, y: max(8, top), width: width, height: height)
        }
        let x = sidebarFrame.minX + AircMetrics.Sidebar.inset
        let width = min(AircMetrics.CommandBar.width - 125, bounds.width - x - 24)
        return NSRect(x: x, y: max(8, top), width: max(320, width), height: height)
    }

    /// ⌘T: centred in the whole window, as in Arc (the owner tried centring it over the page card and went back,
    /// 2026-11-06). ⌘L: over the URL field.
    func layoutIn(_ bounds: NSRect, sidebarFrame: NSRect, contentFrame: NSRect) {
        // AppKit clips backing-store drawing when the view's frame is outside its window. Keep the view at its
        // real size and position so the idle preparation draws its labels and keycaps before the first opening;
        // move only its backing layer out of sight. No extra surface, bitmap cache or recurring timer is needed.
        let placed = isParked && !Self.parksLayer ? bounds.offsetBy(dx: -(bounds.width + 4000), dy: 0) : bounds
        if frame != placed { frame = placed }
        if Self.parksLayer, let layer {
            let transform = isParked ? CATransform3DMakeTranslation(-(bounds.width + 4000), 0, 0) : CATransform3DIdentity
            if !CATransform3DEqualToTransform(layer.transform, transform) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = transform
                CATransaction.commit()
            }
        }
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
        glass.isHidden = anchored != nil || scope != nil
        var inputX: CGFloat = anchored != nil ? AircAddressFieldLabel.leadingInset : 54
        if scope != nil {
            // Site Search: the site's pill where the glass was, the query after it.
            let size = scopePill.intrinsicContentSize
            let pillX: CGFloat = anchored != nil ? max(6, AircAddressFieldLabel.leadingInset - 6) : 16
            scopePill.frame = NSRect(x: pillX, y: ((AircMetrics.CommandBar.inputHeight - size.height) / 2).rounded(),
                                     width: min(size.width, width * 0.45), height: size.height)
            inputX = scopePill.frame.maxX + 8
        }
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
        #if AIRC_TESTING
        keyLog.append("text")
        #endif
        textDidChange(byDeleting: deletingEdit)
        deletingEdit = false
    }

    private func textDidChange(byDeleting deleting: Bool) {
        let text = input.stringValue
        let before = typed
        typed = text
        // "Space or Tab" (a profile's choice): a space typed right after a whole shortcut ("yt ") starts its search.
        if !deleting, scope == nil, text == before + " ", Self.siteSearchEnabled, !isComposing, let sites = host?.commandBarSiteSearches,
           sites.spaceTriggers, let s = sites.index.spaceMatch(text),
           (input.currentEditor() as? NSTextView)?.selectedRange() ?? NSRange(location: 0, length: 0) == NSRange(location: (text as NSString).length, length: 0) {
            return enterScope(.site(s), origin: before)
        }
        // Marked text is the input method's: nothing completes over it (a pinyin "bai" must stay "bai", not baidu.com).
        update(allowCompletion: !deleting && !isComposing)
    }

    func update(allowCompletion: Bool = true) {
        guard let c = host else { return }
        let q = typed
        let sites = Perf.time("cb.sitesearch") { Self.siteSearchEnabled ? c.commandBarSiteSearches : nil }
        // A site edited in Settings is searched as it is now; another profile's Space without it ends its search.
        if case .site(let s)? = scope {
            guard let now = sites?.index.searches.first(where: { $0.id == s.id }) else { return leaveScope(restoring: false) }
            if now != s {
                scope = .site(now)
                applyScope()
            }
        }
        let composing = isComposing
        // A bounded, prebuilt tier supplies local rows in this event, without waiting for the
        // history queue. The full index still refines later through identity-preserving replacement.
        if Self.localHistoryEnabled, !isActionsMode, !q.trimmingCharacters(in: .whitespaces).isEmpty,
           let source = c.commandBarHistory {
            historyHits = Perf.time("cb.local") {
                source.store.localMatches(q, profileID: source.profileID).filter { !removedHistory.contains($0.entry.url) }
            }
        } else {
            historyHits = historyHits.filter { h in
                CommandSearch.score(q, in: h.entry.title) != nil || CommandSearch.score(q, in: URLRules.displayURL(h.entry.url)) != nil
            }
        }
        // Yours first (history, open tabs, pinned items); a well-known site only when nothing of yours completes it.
        var site: CommonSites.Site?
        inline = Perf.time("cb.inline") { () -> InlineCompletion.Match? in
            guard allowCompletion && !isActionsMode && scope == nil && !composing else { return nil }
            if let m = c.inlineCompletion(for: q) { return m }
            guard let s = c.siteCompletion(for: q, history: historyHits) else { return nil }
            site = s.site
            return s.match
        }
        inlineSite = site
        if let editor = input.currentEditor() as? NSTextView, !composing {
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
        siteCandidate = Perf.time("cb.sitematch") { () -> SiteSearch? in
            guard scope == nil, !isActionsMode, !composing, let sites else { return nil }
            return sites.index.match(q, host: inline?.url ?? inlineSite?.url)
        }
        if suggestionQuery != q { suggestions = [] }
        results = Perf.time("cb.results") { composedResults(q, history: historyHits, suggestions: suggestions) }
        Perf.time("cb.rows") { reloadRows() }
        #if AIRC_TESTING
        if Self.localHistoryEnabled, !historyHits.isEmpty { onHistoryApplied?(historyHits.count) }
        #endif
        requestHistory(for: q)
        requestSuggestions(for: q)
    }

    /// Test builds can leave Site Search out (`AIRC_SITE_SEARCH=0`), to time typing with and without it in one binary,
    /// as cblocal timed the local history tier.
    private static let siteSearchEnabled: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_SITE_SEARCH"] != "0"
        #else
        return true
        #endif
    }()

    private static let localHistoryEnabled: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_LOCAL_HISTORY"] != "0"
        #else
        return true
        #endif
    }()

    private func requestHistory(for q: String) {
        guard let source = host?.commandBarHistory, !isActionsMode,
              !q.trimmingCharacters(in: .whitespaces).isEmpty else { historyHits = []; return }
        source.store.search(q, profileID: source.profileID, limit: 8) { [weak self] hits in
            MainActor.assumeIsolated {
                guard let self, let c = self.host, self.typed == q else { return }
                let hits = hits.filter { !self.removedHistory.contains($0.entry.url) }
                // The hot tier often already supplied exactly these rows. Avoid a second layout
                // (and a misleading second "applied" timestamp) when refinement changes nothing.
                guard !Self.localHistoryEnabled || hits != self.historyHits else { return }
                self.historyHits = hits
                self.replaceAsyncResults(self.composedResults(q, history: hits, suggestions: self.suggestions))
                #if AIRC_TESTING
                self.onHistoryApplied?(hits.count)
                #endif
            }
        }
    }

    private func requestSuggestions(for q: String) {
        // A site search's query never goes to the profile's engine.
        guard let c = host, scope == nil, !isActionsMode, URLRules.normalizeInput(q) == nil,
              q.trimmingCharacters(in: .whitespaces).count >= 2, let source = c.commandBarSuggestions else { return }
        SuggestionService.shared.fetch(q, engine: source.engine, profileID: source.profileID) { [weak self] list in
            guard let self, self.typed == q, self.scope == nil, !list.isEmpty else { return }
            self.suggestions = list
            self.suggestionQuery = q
            self.replaceAsyncResults(self.composedResults(q, history: self.historyHits, suggestions: list))
        }
    }

    /// The rows for `q`: in a site search, its search and then your pages on that site; otherwise the host's, with the
    /// "Search YouTube" row second while a site matches what's typed.
    private func composedResults(_ q: String, history: [HistoryMatch], suggestions: [String]) -> [CommandResult] {
        guard let c = host else { return [] }
        if case .site(let s)? = scope { return siteResults(q, site: s, history: history) }
        var rows = c.commandResults(for: q, mode: mode, inline: inline, inlineSite: inlineSite, suggestions: suggestions, history: history)
        if let s = siteCandidate {
            // Arc's hint: "Tab", or "Space or Tab" where the profile lets Space start it too.
            let spaces = c.commandBarSiteSearches?.spaceTriggers == true
            var row = CommandResult(title: "Search \(s.name)", subtitle: spaces ? "Press Space or Tab" : "Press Tab", badge: "Site Search",
                                    icon: siteIcon(s), matches: [], action: .run {})
            row.startsScope = .site(s)
            rows.insert(row, at: min(1, rows.count))
            if rows.count > AircMetrics.CommandBar.maxRows { rows.removeLast() }
        }
        return rows
    }

    /// In a site search: the site's search for the query (Return), then up to five pages of this profile's history on
    /// that site that match it.
    private func siteResults(_ q: String, site s: SiteSearch, history: [HistoryMatch]) -> [CommandResult] {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard let url = s.url(for: query) else { return [] }
        var out = [CommandResult(title: query, subtitle: AircCommandText.searchSubtitle(engine: s.name), badge: "Search",
                                 icon: siteIcon(s), matches: [], action: .open(url))]
        let icons = host?.commandBarShowsSiteIcons == true
        for h in history where out.count < 6 && s.covers(h.entry.url) {
            guard let page = URL(string: h.entry.url) else { continue }
            let title = h.entry.title.isEmpty ? URLRules.displayURL(h.entry.url) : h.entry.title
            out.append(CommandResult(title: title, subtitle: URLRules.displayHost(h.entry.url), badge: "Open",
                                     icon: icons ? .favicon(image: nil, url: nil, page: h.entry.url) : .symbol("globe"),
                                     matches: CommandSearch.score(query, in: title)?.matches ?? [], action: .open(page),
                                     historyURL: h.entry.url))
        }
        return out
    }

    /// A site's icon on its rows: its favicon (a letter tile until it's cached); a magnifying glass in private windows.
    private func siteIcon(_ s: SiteSearch) -> CommandResult.Icon {
        guard host?.commandBarShowsSiteIcons == true, let home = s.homeURL else { return .symbol("magnifyingglass") }
        return .site(page: home, name: s.name)
    }

    /// An explicit keyboard/hover choice survives late history and suggestions. Untouched selection
    /// follows the new top result. Query edits still reset normally, without changing inline completion.
    private func replaceAsyncResults(_ updated: [CommandResult]) {
        let identity = userSelectedResult, index = selected
        results = updated
        reloadRows()
        if let identity {
            let next = results.firstIndex { $0.selectionID == identity } ?? min(index, max(0, results.count - 1))
            select(next, userMoved: true)
        }
    }

    #if AIRC_TESTING
    func applyLateResultsForTesting(_ updated: [CommandResult]) { replaceAsyncResults(updated) }
    #endif

    private func reloadRows() {
        userSelectedResult = nil
        selected = 0
        while rows.count < results.count { rows.append(makeRow()) }
        // Rows beyond the results stay, hidden, for the next keystroke or opening.
        for (i, r) in rows.enumerated() where r.isHidden != (i >= results.count) { r.isHidden = i >= results.count }
        Perf.time("cb.configure") { for (r, res) in zip(rows, results) { r.configure(res) } }
        selectedHistoryURL = nil
        Perf.time("cb.select") { select(0) }
        Perf.time("cb.layout") { if let sv = superview { layoutIn(sv.bounds, sidebarFrame: sidebarFrame, contentFrame: contentFrame) } }
    }

    private func select(_ i: Int, userMoved: Bool = false) {
        if userMoved {
            userSelectedResult = results.indices.contains(i) ? results[i].selectionID : nil
            selectedHistoryURL = results.indices.contains(i) ? results[i].historyURL : nil
        }
        selected = i
        for (j, r) in rows.enumerated() { r.isSelected = j == i }
    }

    /// The Command Bar's keys, before anything else in the window reads them (the app's key monitor asks it first).
    ///
    /// Esc (P03b): the bar is the innermost surface, so Esc is its own while it's open, before Peek, find, full screen
    /// or the sidebar's keyboard (KeyMonitor), and only one of them closes per press: a completion goes, a site search
    /// ends, then the bar closes (`cancel`). While an input method composes, Esc is the input method's.
    ///
    /// Removing a history suggestion, before AppKit reads the key as text editing. ⌥⌘⌫ is Arc's key ("deletes a
    /// selected suggestion", Arc's 2023-10-12 notes), changeable in Settings → Shortcuts (ShortcutCenter's
    /// `removeSuggestion`): the highlighted row, also the first one. ⇧⌫ (Chrome's) only removes a row you moved to
    /// (arrows, pointer), so a ⇧ held while deleting text still deletes text. Any other row, or text being composed by an
    /// input method, leaves the key to the field. The row's ✕ on hover does the same with the pointer.
    func handleSuggestionKey(_ event: NSEvent) -> Bool {
        #if AIRC_TESTING
        if event.keyCode == 51 { keyLog.append("suggestionKey") }
        #endif
        guard event.type == .keyDown, !isParked else { return false }
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.keyCode == 53, mods.isEmpty {
            #if AIRC_TESTING
            keyLog.append("cancelOperation:")   // the field's own Esc, which this stands in for
            #endif
            if let editor = input.currentEditor() as? NSTextView, window?.firstResponder === editor, editor.hasMarkedText() {
                editor.keyDown(with: event)
            } else {
                cancel()
            }
            return true
        }
        guard let editor = input.currentEditor() as? NSTextView, window?.firstResponder === editor, !editor.hasMarkedText()
        else { return false }
        let key = ShortcutCenter.typed(event)
        let arcKey = key != nil && key == ShortcutCenter.shared.commandBarKey(ShortcutCenter.removeSuggestion.id)
        guard arcKey || (event.keyCode == 51 && mods == .shift && selectedHistoryURL != nil),
              results.indices.contains(selected), let url = results[selected].historyURL, arcKey || selectedHistoryURL == url
        else { return false }
        return removeHistorySuggestion(at: selected)
    }

    /// Takes row `index`'s page out of the profile's history (and Tidy's memory of it), with the row fading out and the
    /// ones below sliding up. False: not a history row.
    @discardableResult
    func removeHistorySuggestion(at index: Int) -> Bool {
        guard results.indices.contains(index), let url = results[index].historyURL, let source = host?.commandBarHistory
        else { return false }
        source.store.remove(profileID: source.profileID, url: url)
        AIFeatures.shared.tidy.forget(profileID: source.profileID, url: url)
        removedHistory.insert(url)
        historyHits.removeAll { $0.entry.url == url }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition(); fade.type = .fade; fade.duration = 0.12
            panel.layer?.add(fade, forKey: "historyRemovalFade")
        }
        results.remove(at: index)
        if index == 0, inline != nil {
            inline = nil
            inlineSite = nil
            input.stringValue = typed
        }
        selectedHistoryURL = nil
        reloadRows()
        select(min(index, max(0, results.count - 1)))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for row in rows.dropFirst(index) where !row.isHidden {
                let slide = CASpringAnimation(keyPath: "transform.translation.y")
                slide.fromValue = 8; slide.toValue = 0
                slide.mass = 1; slide.stiffness = 900; slide.damping = 54; slide.duration = 0.18
                row.layer?.add(slide, forKey: "historyRemoval")
            }
        }
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        #if AIRC_TESTING
        keyLog.append(NSStringFromSelector(selector))
        #endif
        // An input method passes on only the keys it doesn't use; while it composes, the field does what it always does.
        if textView.hasMarkedText() { return false }
        // Site Search: Backspace at the start (an empty query) leaves the site's search, as Arc's "back to the previous
        // search state" and Chrome's keyword mode.
        if scope != nil, Self.backwardDeletes.contains(selector), textView.selectedRange() == NSRange(location: 0, length: 0) {
            leaveScope()
            return true
        }
        if NSStringFromSelector(selector).hasPrefix("delete") { deletingEdit = true; return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !results.isEmpty { select((selected + 1) % results.count, userMoved: true) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if !results.isEmpty { select((selected - 1 + results.count) % results.count, userMoved: true) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            execute()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // In a site search Tab stays in the field.
            if scope != nil { return true }
            // Tab on an empty field: actions (Arc). On a site's shortcut or name: that site's search (Arc's Site
            // Search), before accepting an inline completion ("you" → youtube.com: Tab searches YouTube, → accepts).
            // With an inline completion: accept it.
            if typed.isEmpty {
                input.stringValue = "/"
                textDidChange(byDeleting: false)
                return true
            }
            if let s = siteCandidate {
                enterScope(.site(s))
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
            // Esc normally comes through handleSuggestionKey; this is the field's own (VoiceOver's escape action).
            cancel()
            return true
        default:
            return false
        }
    }

    /// Esc: a completion goes first, then a site search ends (what was typed before it comes back), then the bar closes.
    private func cancel() {
        if inline != nil {
            input.stringValue = typed
            inline = nil
            inlineSite = nil
            update(allowCompletion: false)
            return
        }
        if scope != nil { return leaveScope() }
        host?.closeCommandBar()
    }

    private static let backwardDeletes: Set<Selector> = [#selector(NSResponder.deleteBackward(_:)),
                                                         #selector(NSResponder.deleteWordBackward(_:)),
                                                         #selector(NSResponder.deleteToBeginningOfLine(_:)),
                                                         #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:))]

    private func execute() {
        guard results.indices.contains(selected) else { return }
        let r = results[selected]
        // "Search YouTube": the bar stays, now searching the site.
        if let s = r.startsScope { return enterScope(s) }
        // Chosen: now its icon may come from the network (rows never ask for one while you type).
        CommandRowView.fetchIcon(of: r)
        host?.closeCommandBar()
        host?.performCommand(r.action, newTab: mode == .newTab, typed: true)
    }
}

/// Site Search's pill at the start of the field (Arc's scoped-search pill): the site's icon and name on a soft accent
/// capsule. A click opens its menu (CommandBarView.scopeMenu).
final class CommandBarScopePill: NSView {
    var palette: Palette? { didSet { restyle() } }
    var onMenu: (() -> Void)?
    private let icon = CALayer()
    private let label = NSTextField(labelWithString: "")
    /// The favicon asked for, so a late answer for an earlier site is dropped.
    private var iconKey: String?
    static let height: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        icon.actions = LayerImage.noActions
        icon.contentsGravity = .resizeAspect
        layer?.addSublayer(icon)
        label.font = AircFont.row.weight(.semibold).appFont
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `s`'s name, and its icon: a letter tile until its favicon is in the caches (never fetched here; `icons` false, a
    /// private window: the tile only).
    func show(_ s: SiteSearch, icons: Bool) {
        if label.stringValue != s.name {
            label.stringValue = s.name
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        setAccessibilityLabel("Searching \(s.name). Change Site Search")
        let key = icons ? s.homeURL.flatMap(FaviconCache.guess(for:)) : nil
        iconKey = key
        if let img = FaviconCache.shared.cached(key) { return LayerImage.set(img, on: icon, in: self) }
        LayerImage.set(LetterTile.image(for: s.name), on: icon, in: self)
        guard let key else { return }
        FaviconCache.shared.stored(key) { [weak self] img in
            guard let self, self.iconKey == key, let img else { return }
            LayerImage.set(img, on: self.icon, in: self)
        }
    }

    /// The site is being searched: now its favicon may come from the network, as a chosen row's does.
    func fetchIcon(_ s: SiteSearch) {
        guard let key = s.homeURL.flatMap(FaviconCache.guess(for:)), key == iconKey, FaviconCache.shared.cached(key) == nil else { return }
        FaviconCache.shared.load(key) { [weak self] img in
            guard let self, self.iconKey == key, let img else { return }
            LayerImage.set(img, on: self.icon, in: self)
        }
    }

    /// The name's width in the label's font, with room to spare: the label's own intrinsic size left "Wikipedia" a
    /// point or two short ("Wikipe…").
    private var nameWidth: CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? AircFont.row.appFont]).width) + 4
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 8 + 16 + 6 + nameWidth + 10, height: Self.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        CATransaction.commit()
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 30, y: ((bounds.height - h) / 2).rounded(), width: max(0, min(nameWidth, bounds.width - 40)), height: h)
    }

    private func restyle() {
        guard let p = palette else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = p.resolved.accent.alpha(p.resolved.isDark ? 0.24 : 0.14).cgColor
        CATransaction.commit()
        label.textColor = p.panelText
    }

    override func mouseDown(with event: NSEvent) { onMenu?() }
    override func accessibilityPerformPress() -> Bool { onMenu?(); return true }
}

/// The parked bar retains its in-window view geometry, so AppKit must not register an I-beam over the page.
private final class CommandBarInputField: NSTextField {
    var isParked = false

    override func resetCursorRects() {
        guard !isParked else { return }
        super.resetCursorRects()
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
    /// The ✕ a history row shows under the pointer (Arc's, 2023-05-18): the page leaves the history, as with ⌥⌘⌫.
    var onRemove: (() -> Void)?
    private(set) var isHovered = false { didSet { if isHovered != oldValue { updateRemoveButton() } } }
    let removeButton = CommandRowRemoveButton()
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
        for v in [icon, siteIcon, emoji, title, subtitle, action, removeButton] as [NSView] { addSubview(v) }
        removeButton.isHidden = true
        removeButton.onPress = { [weak self] in self?.onRemove?() }
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
        updateRemoveButton()
    }

    /// The ✕ shows on a history row under the pointer (the row's other trailing parts move left of it).
    private func updateRemoveButton() {
        let show = isHovered && !isHidden && result?.historyURL != nil
        removeButton.palette = palette
        if removeButton.isHidden != !show {
            removeButton.isHidden = !show
            needsLayout = true
        }
        if show {
            let key = ShortcutCenter.shared.commandBarKey(ShortcutCenter.removeSuggestion.id)?.display
            removeButton.toolTip = key.map { "Remove from History (\($0))" } ?? "Remove from History"
        }
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
        // Trailing: the ✕ under the pointer, the shortcut's keycaps, then (selected) the action and ↵ before them.
        var x = bounds.width - m.actionTrailing
        if !removeButton.isHidden {
            let s = CommandRowRemoveButton.size
            x -= s
            removeButton.frame = NSRect(x: x, y: (h - s) / 2, width: s, height: s)
            x -= 8
        }
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?()
    }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    func clearHover() { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    #if AIRC_TESTING
    /// ParityP03bCheck: the pointer over the row (posted mouse moves never reach tracking areas).
    func setHoveredForTesting(_ on: Bool) {
        isHovered = on
        if on { onHover?() }
        layoutSubtreeIfNeeded()
    }
    #endif
}

/// A history row's ✕ (CommandRowView): a small round button, darker under the pointer. A click removes the row and
/// never chooses it; VoiceOver reads it as "Remove from History".
final class CommandRowRemoveButton: NSView {
    static let size: CGFloat = 20
    var onPress: (() -> Void)?
    var palette: Palette? { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var inside = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Remove from History")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = palette?.resolved
        let ink = (theme?.surfaceTextSecondary.nsColor ?? .secondaryLabelColor)
        if inside || pressed {
            ink.withAlphaComponent(pressed ? 0.22 : 0.14).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
        let c = NSPoint(x: bounds.midX, y: bounds.midY), r: CGFloat = 3.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x - r, y: c.y - r)); path.line(to: NSPoint(x: c.x + r, y: c.y + r))
        path.move(to: NSPoint(x: c.x + r, y: c.y - r)); path.line(to: NSPoint(x: c.x - r, y: c.y + r))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        ink.setStroke()
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { inside = true }
    override func mouseExited(with event: NSEvent) { inside = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
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
        // P07d: a site search made the default has no suggestion service (as Chrome's custom engines without one).
        guard profile.defaultSearch.site == nil else { return nil }
        return (profile.searchEngine, profile.id)
    }

    /// The current Space's profile's site searches: profiles keep their own (Settings → Site Search).
    var commandBarSiteSearches: CommandBarSiteSearches? {
        guard let settings = app?.settings else { return nil }
        return CommandBarSiteSearches.of(settings.values.siteSearch, profileID: store.profile(ofSpace: currentSpaceID).id)
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
        var current = mode == .editURL ? (engineTab(for: shownTabID ?? "")?.url?.absoluteString ?? currentTab?.url ?? "") : ""
        if NoteURL.isNote(current) { current = "" }   // a note's address is nothing to edit
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
    /// Test builds can build every candidate for an empty query as before (`AIRC_CB_EMPTY_BASELINE=1`, P02b).
    private static let prunesEmptyQuery: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_CB_EMPTY_BASELINE"] != "1"
        #else
        return true
        #endif
    }()

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

        if q.isEmpty, Self.prunesEmptyQuery {
            // ⌘T on its own: the most recent tabs of this profile first. Nothing else ranks for an empty query, so the
            // pinned items, Spaces and actions below aren't built for it: every action's title, keywords and keycaps
            // were most of the parked bar's idle refresh (P02b: ~2.5 ms of a frame right after a swipe's settle) and part
            // of every opening.
            return CommandSearch.rank("", candidates, limit: 6).compactMap { actions[$0.candidate.id] }
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
                                            action: .open(URL(string: r.entry.url)!), historyURL: r.entry.url)
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
        let web = profile.defaultSearch   // P07d: the profile's default, a site search included
        let search = { (text: String, subtitle: String) in
            CommandResult(title: text, subtitle: subtitle, badge: "Search", icon: .symbol("magnifyingglass"), matches: [],
                          action: .open(web.url(for: text) ?? profile.searchEngine.searchURL(for: text)))
        }
        if inline != nil, let site = inlineSite,
           let row = siteResult(site, matches: CommandSearch.score(q, in: site.name)?.matches ?? []) {
            // A built-in site completed inline: its row first, by name ("Spotify  open.spotify.com").
            out.append(row)
            out.append(search(q, AircCommandText.searchSubtitle(engine: web.name)))
        } else if let m = inline, let url = URL(string: m.url) {
            // The completed address first: Enter opens what the field shows.
            out.append(CommandResult(title: m.text, subtitle: "", badge: "Open",
                                     icon: .favicon(image: nil, url: nil, page: m.url), matches: Array(0..<m.typedCount), action: .open(url),
                                     historyURL: !urls.contains(m.url) && history.contains(where: { $0.entry.url == m.url }) ? m.url : nil))
            out.append(search(q, AircCommandText.searchSubtitle(engine: web.name)))
        } else if let u = URLRules.normalizeInput(q), let url = URL(string: u) {
            out.append(CommandResult(title: q, subtitle: "", badge: "Open", icon: .favicon(image: nil, url: nil, page: u),
                                     matches: [], action: .open(url)))
        } else {
            if strong, !ranked.isEmpty { out.append(ranked.removeFirst()) }
            out.append(search(q, AircCommandText.searchSubtitle(engine: web.name)))
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
            .init(title: "New Boost…", symbol: "paintbrush.pointed", hint: ShortcutCenter.hint("file.newBoost", "⌃⇧B"), keywords: ["boost", "css", "customize"]) { [weak self] in self?.newBoost() },
            .init(title: "Boost Gallery", symbol: "square.grid.2x2", hint: "", keywords: ["boost", "gallery", "style", "theme"]) { [weak self] in self?.showBoostGallery() },
            .init(title: "New Space…", symbol: "plus.square.on.square", hint: "", keywords: ["space", "create"]) { [weak self] in self?.openNewSpacePanel() },
            .init(title: "New Folder", symbol: "folder.badge.plus", hint: "", keywords: ["folder"]) { [weak self] in
                guard let self else { return }
                _ = try? self.store.createFolder(inSpace: self.currentSpaceID)
            },
            // Arc's "Create Note; Note; Scratchpad".
            .init(title: newNoteTitle, symbol: "note.text", hint: ShortcutCenter.hint("file.newNote", "⌃⇧N"),
                  keywords: ["note", "notes", "scratchpad", "write", "create", "doc", "document", "page"]) { [weak self] in self?.newNote(source: .commandBar) },
            .init(title: pageToolbar == nil ? "Show Toolbar" : "Hide Toolbar", symbol: "rectangle.topthird.inset.filled", hint: ShortcutCenter.hint("view.showToolbar", "⇧⌘D"), keywords: ["address", "url"]) { [weak self] in self?.togglePageToolbar() },
            .init(title: sidebarHidden ? "Show Sidebar" : "Hide Sidebar", symbol: "sidebar.left", hint: ShortcutCenter.hint("view.toggleSidebar", "⌘S"), keywords: ["toggle"]) { [weak self] in self?.toggleSidebar() },
            .init(title: "Edit Theme Color…", symbol: "paintpalette", hint: "", keywords: ["theme", "colour", "color"]) { [weak self] in
                guard let self else { return }
                self.editTheme(self.currentSpaceID)
            },
            .init(title: "Rename Space…", symbol: "pencil", hint: "", keywords: ["space"]) { [weak self] in self?.renameCurrentSpace() },
            .init(title: "Clear Today", symbol: "arrow.down.to.line", hint: ShortcutCenter.hint("tabs.clearToday", "⇧⌘K"), keywords: ["archive", "clean"]) { [weak self] in self?.clearToday() },
            .init(title: "Library", symbol: "archivebox", hint: ShortcutCenter.hint("tabs.library", "⇧⌘L"), keywords: ["archive", "history"]) { [weak self] in self?.showLibrary() },
            // Arc: "Hit CMD T and type 'Site Search Settings' to get started."
            .init(title: "Site Search Settings…", symbol: "magnifyingglass", hint: "",
                  keywords: ["site search", "search engines", "shortcut", "keyword", "tab"]) { [weak self] in
                self?.app?.showSettings(page: .siteSearch)
            },
        ]
        a += noteCommandActions()   // New Airc Note, Export and Import (Notes/NoteExport.swift)
        if currentTab != nil {
            a.append(.init(title: "Add Split View", symbol: "rectangle.split.2x1", hint: ShortcutCenter.hint("tabs.newSplit", "⌃⇧+"), keywords: ["split", "side", "pane"]) { [weak self] in
                self?.newSplitView()
            })
        }
        if shownSplitID != nil {
            a.append(.init(title: "Separate All Tabs", symbol: "rectangle.split.2x1.slash", hint: "", keywords: ["split", "unsplit"]) { [weak self] in
                self?.separateShownSplit()
            })
        }
        a += splitCommandActions() + calendarCommandActions() + developerCommandActions()   // SplitActions, CalendarMenu, DeveloperMode
        if let t = currentTab {
            a += [
                .init(title: t.isToday ? "Pin Tab" : "Unpin Tab", symbol: "pin", hint: ShortcutCenter.hint("tabs.pin", "⌘D"), keywords: ["bookmark"]) { [weak self] in self?.togglePin() },
                .init(title: "Add to Favorites", symbol: "star", hint: "", keywords: ["favorite", "favourite"]) { [weak self] in self?.addCurrentToFavorites() },
                .init(title: "Copy URL", symbol: "link", hint: ShortcutCenter.hint("edit.copyURL", "⇧⌘C"), keywords: ["link"]) { [weak self] in self?.copyURL() },
                .init(title: "Copy URL as Markdown", symbol: "text.badge.plus", hint: ShortcutCenter.hint("edit.copyURLMarkdown", "⌥⇧⌘C"), keywords: ["link"]) { [weak self] in self?.copyURLMarkdown() },
                .init(title: "Copy URL as Quote", symbol: "text.quote", hint: ShortcutCenter.hint("edit.copyURLQuote", "⌃⇧⌘C"), keywords: ["link", "selection"]) { [weak self] in self?.copyURLQuote() },
                .init(title: "Capture…", symbol: "camera.viewfinder", hint: ShortcutCenter.hint("view.capture", "⇧⌘2"),
                      keywords: ["screenshot", "snapshot", "picture", "image", "copy"]) { [weak self] in self?.startCapture() },
                .init(title: "Capture Full Page", symbol: "arrow.up.and.down.text.horizontal", hint: "",
                      keywords: ["screenshot", "full page", "whole page", "long", "scrolling"]) { [weak self] in self?.startCapture(fullPage: true) },
                .init(title: "Capture in Portrait Mode", symbol: "camera.macro", hint: "", keywords: ["screenshot", "portrait", "pretty", "frame", "wallpaper"]) { [weak self] in self?.startCapture(portrait: true) },
                .init(title: "Reload", symbol: "arrow.clockwise", hint: ShortcutCenter.hint("view.reload", "⌘R"), keywords: ["refresh"]) { [weak self] in self?.reloadOrStop() },
                .init(title: "Duplicate Tab", symbol: "plus.square.on.square", hint: "", keywords: ["copy"]) { [weak self] in
                    guard let self, let id = self.shownTabID else { return }
                    _ = try? self.store.duplicateTab(id)
                },
            ]
            // Ask on Page (AI/AskPageCard.swift), while it's on.
            if app?.settings.values.askPage == true {
                a.append(.init(title: "Ask This Page…", symbol: "sparkles", hint: "",
                               keywords: ["ask", "question", "ai", "summarize", "apple intelligence"]) { [weak self] in self?.showAsk() })
            }
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
        a += contextCommandActions()   // the menus' actions (Browser/WindowActions.swift)
        a += menuCommandActions(excluding: Set(a.map(\.title)))   // the menu bar's (App/ParityCommandCatalog.swift)
        return a
    }
}
