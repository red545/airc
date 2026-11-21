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
/// searches the scope instead of the profile's engine, Backspace on an empty query or Esc leaves it. `ask` (P07b,
/// ChatGPTCommand.swift) asks a chat site instead: Return opens the question there in a new tab.
enum CommandBarScope: Equatable {
    case site(SiteSearch)
    case ask(AskAIProvider)

    var name: String { site.name }

    /// The site its pill and icon show.
    var site: SiteSearch {
        switch self {
        case .site(let s): s
        case .ask(let p): p.siteSearch
        }
    }

    /// Arc's "Site Search placeholder where the wildcard is the name of the site"; "Ask ChatGPT…" for a chat site.
    var placeholder: String { label + "…" }

    /// "Search YouTube", "Ask ChatGPT".
    var label: String {
        switch self {
        case .site: "Search \(name)"
        case .ask: "Ask \(name)"
        }
    }
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
    /// Instant Links' hint row (P07c): choosing it finds the pages, as ⇧↵ does, instead of running `action`.
    var startsInstantLinks = false
    /// An Ask AI row (P07b): its page opens in a new tab even from ⌘L.
    var opensInNewTab = false

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
        /// A page's icon: `image` (an open tab's), else the caches' copy of `url` or of the page's site (SiteIcons: Airc's
        /// store, the engine profile's favicon database), with the site's letter tile until one arrives.
        case favicon(image: NSImage?, url: String?, page: String?)
        /// A built-in site (CommonSites): its favicon, a letter tile until it arrives.
        case site(page: String, name: String)
        /// A private window's site rows: the letter tile only (nothing read from or written to any icon store).
        case monogram(page: String)
        case symbol(String)
        case emoji(String)
    }

    /// The same icon on screen: the same case and values, a tab's own favicon the same image.
    static func sameIcon(_ a: Icon, _ b: Icon) -> Bool {
        switch (a, b) {
        case let (.favicon(i1, u1, p1), .favicon(i2, u2, p2)): return i1 === i2 && u1 == u2 && p1 == p2
        case let (.site(p1, n1), .site(p2, n2)): return p1 == p2 && n1 == n2
        case let (.monogram(x), .monogram(y)), let (.symbol(x), .symbol(y)), let (.emoji(x), .emoji(y)): return x == y
        default: return false
        }
    }

    /// The page this row shows or opens, if it's a site: what its trust mark is checked against.
    var page: String? {
        switch icon {
        case .favicon(_, _, let page?), .site(let page, _), .monogram(let page): return page
        default: break
        }
        if case .open(let url) = action { return url.absoluteString }
        return nil
    }

    /// The row's kind in plain words, shown at its end when it isn't selected (Raycast's accessory): "Website",
    /// "Open Tab", "Search"…; "" where the row already says what it is (a command's keycaps, "Search Google").
    var kind: String {
        if startsScope != nil || startsInstantLinks { return "" }
        let k: String
        switch badge {
        case "Open": if case .open = action { k = "Website" } else { k = "" }
        case "Switch to Tab": k = "Open Tab"
        case "Pinned": k = "Pinned Tab"
        case "Favorite": k = "Favorite"
        case "Space": k = "Space"
        case "Search": k = "Search"
        case "Ask": k = "Ask AI"
        case "Run": k = shortcut.isEmpty ? "Command" : ""
        default: k = ""
        }
        return k.isEmpty || subtitle.hasPrefix(k) ? "" : k
    }

    /// The verified site (OfficialSites, Airc's bundled list) this row opens or shows; nil for searches, commands and
    /// anything not on the list. Never from the page's content.
    var trust: OfficialSites.Site? {
        switch badge {
        case "Open", "Switch to Tab", "Pinned", "Favorite": break
        default: return nil
        }
        return page.flatMap(OfficialSites.match)
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
    /// Where live suggestions come from and their session key: with no `site`, the profile's default search (its engine,
    /// or a default site search with its own endpoint); in a site search, that site's endpoint. nil while they're off.
    func commandBarSuggestionSource(scope site: SiteSearch?) -> (source: SearchSuggestions.Source, profileID: String)?
    func inlineCompletion(for typed: String) -> InlineCompletion.Match?
    func siteCompletion(for typed: String, history: [HistoryMatch]) -> CommonSites.Completion?
    func commandResults(for query: String, mode: CommandBarMode, inline: InlineCompletion.Match?,
                        inlineSite: CommonSites.Site?, suggestions: [String], history: [HistoryMatch]) -> [CommandResult]
    /// The same, for the bar's own keystrokes: a host may answer from lists it prepared at idle (CommandIndex), as long
    /// as they are what `commandResults` would make now.
    func barCommandResults(for query: String, mode: CommandBarMode, inline: InlineCompletion.Match?,
                           inlineSite: CommonSites.Site?, suggestions: [String], history: [HistoryMatch]) -> [CommandResult]
    func closeCommandBar()
    /// Closes the bar; with `focusingPage: false` the keyboard is left for what runs next (`focusPageUnlessTaken`).
    func closeCommandBar(focusingPage: Bool)
    /// After a command chosen in the bar: the page gets the keyboard unless the command gave it to something.
    func focusPageUnlessTaken()
    func performCommand(_ action: CommandResult.Action, newTab: Bool, typed: Bool)
    /// This window's site searches (its profile's); nil: none.
    var commandBarSiteSearches: CommandBarSiteSearches? { get }
    /// Whether rows may show (and, once chosen, fetch) site icons; a private window's never do.
    var commandBarShowsSiteIcons: Bool { get }
    /// The engine profile's favicon database rows may read icons from (SiteIcons); nil: none (WebKit, private).
    var commandBarFaviconDatabase: URL? { get }
    /// P07b: the chat site this window's profile asks with "gpt" + Tab (ChatGPTCommand.swift); nil: off.
    var commandBarAskAI: AskAIProvider? { get }
    /// askai: finds Settings → AI's Automatic chat site for this profile again if it's stale (after the open's frame).
    func refreshCommandBarAskAI()
    /// agentpanel2: the "Ask Airc to…" row (the Airc Agent, ⌥⌘A) for a prompt, with or without a key; nil: none (a
    /// private window).
    /// Asked on every keystroke: a cached answer only.
    var commandBarAgent: ((String) -> Void)? { get }
    /// P07c: Instant Links, when on and Apple Intelligence can run (InstantLinks.swift); nil: ⇧↵ searches, no hint.
    var commandBarInstantLinks: CommandBarInstantLinks? { get }
    /// Opens Instant Links' pages, the first as ⌘T or ⌘L would open what's chosen.
    func openInstantLinks(_ links: [InstantLink], newTab: Bool)
}

extension CommandBarHost {
    func barCommandResults(for query: String, mode: CommandBarMode, inline: InlineCompletion.Match?,
                           inlineSite: CommonSites.Site?, suggestions: [String], history: [HistoryMatch]) -> [CommandResult] {
        commandResults(for: query, mode: mode, inline: inline, inlineSite: inlineSite, suggestions: suggestions, history: history)
    }
    var commandBarSiteSearches: CommandBarSiteSearches? { nil }
    func closeCommandBar(focusingPage: Bool) { closeCommandBar() }
    func focusPageUnlessTaken() {}
    var commandBarShowsSiteIcons: Bool { true }
    var commandBarFaviconDatabase: URL? { nil }
    var commandBarAskAI: AskAIProvider? { nil }
    func refreshCommandBarAskAI() {}
    var commandBarAgent: ((String) -> Void)? { nil }
    var commandBarInstantLinks: CommandBarInstantLinks? { nil }
    func openInstantLinks(_ links: [InstantLink], newTab: Bool) {
        for (i, l) in links.enumerated() { performCommand(.open(l.url), newTab: newTab || i > 0, typed: false) }
    }
    /// Hosts that don't say otherwise (private windows): the built-in engine only, never an imported site's endpoint.
    func commandBarSuggestionSource(scope site: SiteSearch?) -> (source: SearchSuggestions.Source, profileID: String)? {
        guard site == nil, let s = commandBarSuggestions else { return nil }
        return (.engine(s.engine), s.profileID)
    }
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
/// The Command Bar's backing layer. AppKit owns a layer-backed view's layer geometry: when the bar's layer joins the
/// window's layer tree (the spare bar, added parked at idle after launch, `WindowController.schedulePrewarm`), the next
/// display cycle sets its transform back to identity (NSViewUpdateSubviewForAncestorLayerChange). That brought the
/// parked bar back over the page, unclickable, until something refreshed it: after a relaunch onto a note in a split,
/// for good (polish4). While the bar is parked, its park offset stands.
final class CommandBarLayer: CALayer {
    var parkedTransform: CATransform3D?
    override var transform: CATransform3D {
        get { super.transform }
        set { super.transform = parkedTransform ?? newValue }
    }
}

final class CommandBarView: NSView, NSTextFieldDelegate {
    override func makeBackingLayer() -> CALayer { CommandBarLayer() }
    weak var host: CommandBarHost?
    private(set) var mode: CommandBarMode
    var palette: Palette { didSet { applyPalette() } }
    private let panel = FlippedView()
    /// Shadow behind the panel, drawn from shadow paths in its own view so nothing clips it and Core Animation
    /// never renders it offscreen. Without it the bar disappears into white pages.
    private let shadowView = NSView()
    private let ambientShadow = CALayer()
    private let input = CommandBarInputField()
    /// The field's placeholder, drawn by a label behind it: setting a text field's own placeholder while its editor is
    /// active in the key window costs AppKit 14–27 ms (Tab → site search in a foreground session, parityp07's timing),
    /// a label's text well under one.
    private let placeholderLabel = NSTextField(labelWithString: "")
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
    /// cbflicker2: the words the prompt's rows (Ask Claude, Ask Airc to…) first showed for while they still begin what's
    /// typed. The "looks like a prompt" guess can flip from key to key; the rows stay until the words are taken back.
    private var promptShownFor: String?
    /// The last history matches (searched off the main thread, H5) and the query they were for.
    private var historyHits: [HistoryMatch] = []
    private var removedHistory = Set<String>()
    #if AIRC_TESTING
    /// Debug hook: history matches were applied to the rows (`--script cbperf`).
    var onHistoryApplied: ((Int) -> Void)?
    /// Debug hook: the rows were made again (each time, what the next frame shows; `--script cbflicker`).
    var onRowsReloaded: ((CommandBarView) -> Void)?
    /// The engine's suggestion rows now shown (search rows without a subtitle).
    var suggestionRowCount: Int { results.reduce(0) { $0 + ($1.badge == "Search" && $1.subtitle.isEmpty ? 1 : 0) } }
    /// What reached the bar from the keyboard, in order ("insertTab:", "text", "suggestionKey"): proof that a posted
    /// key was delivered (`--script parityp07`).
    var keyLog: [String] = []
    #endif
    /// The inline completion shown after the caret, if any.
    private(set) var inline: InlineCompletion.Match?
    /// The built-in site the inline completion came from, when nothing of yours completed what was typed.
    private(set) var inlineSite: CommonSites.Site?
    /// Typed alone, Send Feedback's words: a built-in site doesn't complete them inline (feedback2).
    static let feedbackWords: Set<String> = ["feed", "feedb", "feedba", "feedbac", "feedback", "bug", "report"]
    /// Site Search: the scope the field searches now, shown as a pill before the text; nil for the plain bar.
    private(set) var scope: CommandBarScope?
    /// What was typed before the scope began ("yt"): leaving it with Backspace puts it back.
    private var scopeOrigin = ""
    /// The site Tab would search for what's typed (its "Search YouTube" row is shown).
    private(set) var siteCandidate: SiteSearch?
    /// P07b: the chat site Tab would ask ("gpt"), when no site search matches.
    private(set) var askCandidate: AskAIProvider?
    /// A DuckDuckGo-style bang in what's typed ("!yt cats", "cats !yt"; SiteSearchBang): its search is the first row.
    private(set) var bang: SiteSearchBang.Match?
    /// P07c: Instant Links finding pages for what's typed, or showing what will open.
    private var instant: InstantState?
    private let scopePill = CommandBarScopePill()
    /// asidepass: Ask mode (CommandBarAsk.swift): the Search | Ask switch, and under the field the chips and Recent
    /// tasks in place of the rows.
    private(set) var askMode = false
    private let modeToggle = CommandBarModeToggle()
    private(set) var askPanel: CommandBarAskPanel?

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
        input.delegate = self
        input.cell?.isScrollable = true
        input.cell?.wraps = false
        // A URL field, not a login field: without this, becoming first responder runs AppKit's password and
        // one-time-code AutoFill heuristics on every opening (~1.4 ms, §2.12).
        input.contentType = .URL
        input.isAutomaticTextCompletionEnabled = false
        placeholderLabel.font = AircFont.commandInput.appFont
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.setAccessibilityElement(false)   // the field says it (its accessibility placeholder)
        panel.addSubview(placeholderLabel)   // behind the field, which draws no background
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
        modeToggle.isHidden = true
        modeToggle.onPick = { [weak self] ask in self?.setAskMode(ask) }
        panel.addSubview(modeToggle)
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
        promptShownFor = nil
        historyHits = []
        removedHistory = []
        deletingEdit = false
        siteCandidate = nil
        askCandidate = nil
        bang = nil
        cancelInstant(restore: false)
        scopeOrigin = ""
        if scope != nil {
            scope = nil
            applyScope()
        }
        if askMode { setAskMode(false, refresh: false) }
        askPanel?.model.attached = []
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
        sessionPending = false
        cancelInstant(restore: false)
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
        (layer as? CommandBarLayer)?.parkedTransform = nil
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
        // cbperf4: the typing warm-ups moved to `prewarmRows`, a second later at idle: this prewarm can run before a
        // link launch's first paint (linkpaint +30 ms). `AIRC_CB_FIRSTKEY_WARM=0` keeps them here, as before.
        if !Self.firstKeyWarm { prewarmTyping(completion: false) }
    }

    /// The first keystroke's one-time text and art setup (cbperf3, cbperf4): AppKit's first insert, the bar's TextKit 1
    /// editor typing and selecting a completion, the official-site seal.
    private func prewarmTyping(completion: Bool) {
        TextInputWarmup.run()
        if completion {
            TextInputWarmup.runCompletion(font: input.font ?? AircFont.commandInput.appFont,
                                          attributes: palette.resolved.inlineCompletionAttributes)
        }
        rows.first?.prewarmArt(scale: window?.backingScaleFactor ?? 2)
    }

    /// cbperf4 A/B in one binary: `AIRC_CB_FIRSTKEY_WARM=0` leaves the rows an empty ⌘T doesn't show cold until the
    /// first keystroke shows them.
    #if AIRC_TESTING
    static let firstKeyWarm = ProcessInfo.processInfo.environment["AIRC_CB_FIRSTKEY_WARM"] != "0"
    #else
    static let firstKeyWarm = true
    #endif
    private var rowsWarmed = false

    /// At idle, parked, once per bar: the typing warm-ups (`prewarmTyping`), then every row shown once with a typed
    /// query's kinds of results (cbperf4). An empty
    /// ⌘T shows 6 of the 8 rows; the first keystroke used to fill all 8, so it paid the last rows' first restyle
    /// (labels' text storage, icon views), their first unhide and layout, and a typed query's first
    /// composition (the non-empty ranking paths). The idle frame after this draws them (the rows' layer backings);
    /// `WindowController` then puts back what ⌘T shows (`prepareForNextOpening`). Nothing is searched or fetched:
    /// no history request, no suggestions, no icon lookups (letter tiles, symbols, an emoji only). No shortcuts: the
    /// keycap views a row makes for one stay with it (hidden), and a command's few cost ~0.1 ms when first shown.
    /// Returns false when there was nothing to do.
    @discardableResult func prewarmRows() -> Bool {
        guard Self.firstKeyWarm, isParked, !rowsWarmed, host != nil else { return false }
        rowsWarmed = true
        let timing = Perf.enabled
        Perf.enabled = false
        defer { Perf.enabled = timing }
        prewarmTyping(completion: true)
        _ = composedResults("a", history: [], suggestions: [])
        let icons: [CommandResult.Icon] = [.monogram(page: "https://example.com/"), .symbol("magnifyingglass"),
                                           .favicon(image: nil, url: nil, page: nil), .emoji("⭐️")]
        let badges = ["Open", "Search", "Switch to Tab", "Run"]
        results = (0..<max(rows.count, AircMetrics.CommandBar.maxRows)).map { i in
            CommandResult(title: "Airc \(i)", subtitle: "example.com", badge: badges[i % badges.count],
                          icon: icons[i % icons.count], matches: [0], action: .run {})
        }
        reloadRows()
        return true
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
        r.onHover = { [weak self, weak r] forced in
            guard let self, !self.isParked, let r, let i = self.rows.firstIndex(where: { $0 === r }), i < self.results.count else { return }
            // As native menus and Arc: only a pointer that moved picks a row. Rows that appear or change under a resting
            // pointer (the bar opening over it, a keystroke, late results) get an enter event with no movement.
            if !forced, let rest = self.restingPointer {
                let p = NSEvent.mouseLocation
                guard hypot(p.x - rest.x, p.y - rest.y) > 1 else { return }
                self.restingPointer = nil
            }
            guard self.selected != i || self.userSelectedResult == nil else { return }
            self.select(i, userMoved: true)
        }
        panel.addSubview(r)
        return r
    }

    /// Where the pointer was when the rows last appeared or changed (screen points); nil once it has moved since. Until it
    /// moves, hovering doesn't select: ⌘T, typing and Return open the top match, not the row under a resting pointer.
    private var restingPointer: NSPoint?

    func focus(with text: String) {
        restingPointer = NSEvent.mouseLocation
        // askai: Automatic's chat site, after this frame's commit (a 2 ms timer runs after it; `async` before it).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in self?.host?.refreshCommandBarAskAI() }
        input.stringValue = text
        typed = text
        if Self.defersSession, let w = window, w.isKeyWindow {
            // cmdfast: starting the field's editing session inserts the editor into the field (`addSubview`,
            // `setDocumentView`, its attributes and input context) and gives the commit its layout and drawing: 3–7 ms
            // of ⌘T's frame in a key window. The bar takes the keyboard now (the page gives it up in this frame, as
            // before) and the session starts in the next run-loop turn, after this frame's commit. A key that comes
            // first starts it at once and goes on to the editor (`keyDown`, `performKeyEquivalent`), so nothing typed
            // is lost or reordered (`--script cbfirstkeys`).
            sessionPending = true
            openingID &+= 1
            let opening = openingID
            Perf.time("cb.focus.defer") { _ = w.makeFirstResponder(self) }
            if w.firstResponder === self {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.pendingDelay) { [weak self] in
                    // Only this opening's session: a later one sets its own timer.
                    guard let self, self.openingID == opening else { return }
                    if self.beginPendingSession() { Self.sessionStats.startedByTimer += 1 }
                }
                update(allowCompletion: false)
                return
            }
            sessionPending = false
        }
        Perf.time("cb.focus.begin") { _ = window?.makeFirstResponder(input) }
        selectAllText()
        update(allowCompletion: false)
    }

    /// The whole text selected, as `selectAll(_:)` does, without the action: AppKit's input analytics vet every
    /// `selectAll:` (~1.5 ms of ⌘T's frame, cmdfast's profile).
    private func selectAllText() {
        if let editor = input.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        }
    }

    /// The bar holds the keyboard until its field's editing session starts (`focus(with:)`).
    private var sessionPending = false
    private var openingID = 0

    /// The deferred session: a run-loop turn after the opening, or at once for a key that arrives first.
    @discardableResult
    private func beginPendingSession() -> Bool {
        guard sessionPending else { return false }
        sessionPending = false
        guard !isParked, let w = window, w.firstResponder === self else { return false }
        Perf.time("cb.focus.begin") { _ = w.makeFirstResponder(input) }
        selectAllText()
        return w.firstResponder === input.currentEditor()
    }

    override var acceptsFirstResponder: Bool { sessionPending }

    override func keyDown(with event: NSEvent) {
        if beginPendingSession(), let editor = window?.firstResponder, editor !== self {
            Self.sessionStats.startedByKey += 1
            return editor.keyDown(with: event)
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘V, ⌘A and the rest go to the menu bar after this; the editor must be first responder by then.
        if sessionPending, beginPendingSession() { Self.sessionStats.startedByKey += 1 }
        return super.performKeyEquivalent(with: event)
    }

    /// Which deferred sessions the timer started and which a key did (cbfirstkeys asserts them).
    struct SessionStats { var startedByTimer = 0, startedByKey = 0 }
    static var sessionStats = SessionStats()

    #if AIRC_TESTING
    /// cmdfast A/B: `AIRC_CB_FOCUS_NOW=1` starts the session in ⌘T's own frame, as before.
    static let defersSession = ProcessInfo.processInfo.environment["AIRC_CB_FOCUS_NOW"] != "1"
    /// The deferred session starts this long after the opening (a timer: after the opening frame's commit). cbfirstkeys
    /// holds it longer, so every real key after ⌘T arrives while the session is pending.
    static var pendingDelay: TimeInterval = 0.001
    #else
    static let defersSession = true
    static let pendingDelay: TimeInterval = 0.001
    #endif

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
        // keyframe: TextKit 1. A TextKit 2 editor re-synchronised its layout manager, fixed up the selection, laid out
        // its viewport and made a new fragment view (so a layer tree rebuild) for every keystroke: ~2 ms of the frame
        // for one line of text.
        _ = Self.keyframe2   // sets AircKit's switches (test builds) before the first ranking
        let editor = Self.makeFieldEditor()
        editor.bar = self
        return editor
    }()

    /// The bar's field editor as configured, without a bar (cbperf4: TextInputWarmup types into one off screen).
    static func makeFieldEditor() -> CommandBarFieldEditor {
        let editor = Self.keyframe ? CommandBarFieldEditor(usingTextLayoutManager: false) : CommandBarFieldEditor(frame: .zero)
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
        if Self.keyframe {
            // keyframe: with every check above off, AppKit's text checking controller still annotated the text and
            // the selection on every keystroke (~0.4 ms of its frame). An address field checks nothing.
            editor.enabledTextCheckingTypes = 0
            if #available(macOS 15.0, *) {
                editor.writingToolsBehavior = .none
                editor.mathExpressionCompletionType = .no
            }
        }
        return editor
    }

    #if AIRC_TESTING
    /// keyframe A/B in one binary: `AIRC_CB_KEYFRAME=0` keeps the keystroke frame as it was before.
    static let keyframe = ProcessInfo.processInfo.environment["AIRC_CB_KEYFRAME"] != "0"
    #else
    static let keyframe = true
    #endif

    /// keyframe2 A/B in one binary: `AIRC_CB_KEYFRAME2=0` keeps the keystroke's results as keyframe left them (the
    /// command list made on every key, ranking without prepared texts or prefilters, inline targets parsed every key).
    #if AIRC_TESTING
    static let keyframe2: Bool = {
        let on = ProcessInfo.processInfo.environment["AIRC_CB_KEYFRAME2"] != "0"
        CommandSearch.prefilters = on
        CommandSearch.memoizesPages = on
        InlineCompletion.memoizesTargets = on
        return on
    }()
    #else
    static let keyframe2 = true
    #endif

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
    var placeholderText: String { placeholderLabel.stringValue }
    /// Whether the placeholder is on screen (only while the field is empty).
    var placeholderShown: Bool { !placeholderLabel.isHidden }

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
        modeToggle.palette = palette
        askPanel?.model.theme = palette.resolved
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
        let text = askMode ? "Ask Airc to…  @ adds this page" : scope?.placeholder ?? "Search or Enter URL…"
        if placeholderLabel.stringValue != text {
            placeholderLabel.stringValue = text
            input.setAccessibilityPlaceholderValue(text)
        }
        if placeholderLabel.textColor != palette.panelSecondary { placeholderLabel.textColor = palette.panelSecondary }
        updatePlaceholderVisibility()
    }

    /// The placeholder shows only while the field is empty (marked text from an input method counts as text).
    private func updatePlaceholderVisibility() {
        let empty = ((input.currentEditor() as? NSTextView)?.string ?? input.stringValue).isEmpty
        if placeholderLabel.isHidden != !empty { placeholderLabel.isHidden = !empty }
    }

    // MARK: Site Search

    /// The pill, placeholder and glyph for the current scope (none: the plain bar).
    private func applyScope() {
        Perf.time("cbs.pill") {
            if let s = scope?.site {
                scopePill.show(s, icons: host?.commandBarShowsSiteIcons ?? false)
                if case .ask = scope { scopePill.setAccessibilityLabel("Asking \(s.name). Ask AI options") }
            }
            if scopePill.isHidden != (scope == nil) { scopePill.isHidden = scope == nil }
        }
        Perf.time("cbs.placeholder") { applyPlaceholder() }
        Perf.time("cbs.axlabel") { input.setAccessibilityLabel(scope?.label) }
        Perf.time("cbs.layout") { if let sv = superview { layoutIn(sv.bounds, sidebarFrame: sidebarFrame, contentFrame: contentFrame) } }
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
        askCandidate = nil
        bang = nil
        cancelInstant(restore: false)
        suggestions = []
        suggestionQuery = ""
        typed = ""
        Perf.time("cbs.clear") { input.stringValue = "" }
        applyScope()
        Perf.time("cbs.fetchIcon") { if host?.commandBarShowsSiteIcons == true { scopePill.fetchIcon(s.site) } }
        Perf.time("cbs.update") { update(allowCompletion: false) }
        let said = (s.label.hasPrefix("Ask ") ? "Asking " : "Searching ") + s.name
        Perf.time("cbs.announce") {
            NSAccessibility.post(element: input, notification: .announcementRequested,
                                 userInfo: [.announcement: said, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Back to the plain bar. Backspace and Esc put back what was typed before the scope ("yt"), then the query if there
    /// was one, the caret after "yt " (as Chrome's keyword mode); a profile switch that drops the site keeps the query.
    func leaveScope(restoring: Bool = true) {
        guard scope != nil else { return }
        let query = typed
        scope = nil
        // The site's suggestions aren't the default's.
        suggestions = []
        suggestionQuery = ""
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
        if case .ask(let p)? = scope {
            // A chat site: leave it, or choose another in Settings.
            let menu = NSMenu()
            menu.add("Stop Asking \(p.name)") { [weak self] in self?.leaveScope(restoring: false) }
            menu.addItem(.separator())
            menu.add("Ask AI Settings…") { [weak self] in
                self?.host?.closeCommandBar()
                (NSApp.delegate as? AppDelegate)?.showSettings(page: .siteSearch)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: scopePill.bounds.maxY + 4), in: scopePill)
            return
        }
        guard case .site(let current)? = scope else { return }
        let menu = NSMenu()
        let change = NSMenuItem(title: "Change Site Search", action: nil, keyEquivalent: "")
        let sites = NSMenu()
        for s in host?.commandBarSiteSearches?.index.searches ?? [] {
            sites.add(s.name) { [weak self] in
                guard let self, self.scope != nil else { return }
                // The other site's suggestions aren't this one's.
                self.suggestions = []
                self.suggestionQuery = ""
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
            (layer as? CommandBarLayer)?.parkedTransform = isParked ? transform : nil
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
        let askHeight = askMode ? CommandBarAskPanel.height(spaceID: askWindow?.currentSpaceID ?? "") : 0
        let height = AircMetrics.CommandBar.inputHeight + rowsHeight + askHeight
        let anchored = anchoredRect(in: bounds, height: height)
        if let r = anchored {
            panelRect = r
        } else {
            let width = min(AircMetrics.CommandBar.width, bounds.width - 80)
            let top = max(bounds.minY + 24, bounds.midY - AircMetrics.CommandBar.topAboveMiddle)
            panelRect = NSRect(x: (bounds.midX - width / 2).rounded(), y: top.rounded(), width: width, height: height)
        }
        let width = panelRect.width
        // asidepass: the Search | Ask switch, in the centred bar of a window with the agent (not over the URL field).
        let showsToggle = anchored == nil && askWindow != nil && width >= 520
        if modeToggle.isHidden == showsToggle { modeToggle.isHidden = !showsToggle }
        let toggleW: CGFloat = showsToggle ? modeToggle.intrinsicContentSize.width + 8 : 0
        panel.frame = panelRect
        shadowView.frame = panelRect
        glass.frame = NSRect(x: 20, y: (AircMetrics.CommandBar.inputHeight - 24) / 2, width: 24, height: 24)
        // Over the URL field the text starts where the field's host did (12 pt in), so it doesn't jump (review #10).
        glass.isHidden = anchored != nil || scope != nil
        let glassImage = askMode ? Self.askGlyph : Self.searchGlyph
        if glass.image !== glassImage { glass.image = glassImage }
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
        if showsToggle {
            let size = modeToggle.intrinsicContentSize
            let f = NSRect(x: width - 16 - chipW - toggleW, y: ((AircMetrics.CommandBar.inputHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
            if modeToggle.frame != f { modeToggle.frame = f }
        }
        input.frame = NSRect(x: inputX, y: (AircMetrics.CommandBar.inputHeight - 26) / 2, width: width - inputX - 20 - chipW - toggleW, height: 26)
        if let a = askPanel {
            let f = NSRect(x: 0, y: AircMetrics.CommandBar.inputHeight, width: width, height: askHeight)
            if a.frame != f { a.frame = f }
            if a.isHidden == askMode { a.isHidden = !askMode }
        }
        if placeholderLabel.frame != input.frame { placeholderLabel.frame = input.frame }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chipBackground.frame = NSRect(x: width - 16 - chipW, y: (AircMetrics.CommandBar.inputHeight - 24) / 2, width: chipW, height: 24)
        separator.isHidden = results.isEmpty && !askMode
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

    /// Typing the next character of the inline completion: the completion's start moves on by it and the text stays
    /// as it is (Chrome's omnibox does the same). The field then shows exactly what replacing the completion with the
    /// character and completing again would (the old way: two edits of the field and a new selection, ~2 ms of each
    /// such keystroke, cbfirstkey), and the rows are made the same way. Not with marked text (an input method), not a
    /// space (it can start a site search), not the completion's last character.
    func typeAheadIntoCompletion(_ string: String, replacementRange: NSRange, in editor: NSTextView) -> Bool {
        let s = string as NSString
        guard inline != nil, scope == nil, instant == nil, s.length == 1, string != " ", !editor.hasMarkedText(),
              editor.selectedRanges.count == 1 else { return false }
        let selection = editor.selectedRange()
        let text = editor.string as NSString
        guard selection.length > 1, NSMaxRange(selection) == text.length,
              replacementRange.location == NSNotFound || replacementRange == selection,
              text.substring(to: selection.location) == typed,
              text.substring(with: NSRange(location: selection.location, length: 1)) == string else { return false }
        editor.setSelectedRange(NSRange(location: selection.location + 1, length: selection.length - 1))
        #if AIRC_TESTING
        keyLog.append("text")
        #endif
        typingAhead = true
        defer { typingAhead = false }
        textDidChange(byDeleting: false, text: typed + string)
        return true
    }
    private var typingAhead = false

    private func textDidChange(byDeleting deleting: Bool, text typedText: String? = nil) {
        cancelInstant(restore: false)
        updatePlaceholderVisibility()
        if askMode, !deleting, input.stringValue.hasSuffix("@"), let c = askWindow, let page = AgentAskContext.shownPage(of: c) {
            // "@": the window's page goes into the chips (the + chip lists the Space's other tabs).
            input.stringValue.removeLast()
            if askPanel?.model.attached.contains(page) == false { askPanel?.model.attached.append(page) }
        }
        let text = typedText ?? input.stringValue
        let before = typed
        typed = text
        // "Space or Tab" (a profile's choice): a space typed right after a whole shortcut ("yt ") starts its search.
        if !deleting, scope == nil, text == before + " ", Self.siteSearchEnabled, !isComposing, let sites = host?.commandBarSiteSearches,
           sites.spaceTriggers, let s = sites.index.spaceMatch(text),
           (input.currentEditor() as? NSTextView)?.selectedRange() ?? NSRange(location: 0, length: 0) == NSRange(location: (text as NSString).length, length: 0) {
            return enterScope(.site(s), origin: before)
        }
        // Marked text is the input method's: nothing completes over it (a pinyin "bai" must stay "bai", not baidu.com).
        Perf.time("cb.update") { update(allowCompletion: !deleting && !isComposing) }
    }

    func update(allowCompletion: Bool = true) {
        guard let c = host else { return }
        // Ask mode searches nothing: what's typed is the agent's task.
        if askMode { return updateAsk() }
        let q = typed
        let sites = Perf.time("cb.sitesearch") { Self.siteSearchEnabled ? c.commandBarSiteSearches : nil }
        // A site edited in Settings is searched as it is now; another profile's Space without it ends its search.
        if case .site(let s)? = scope, !SiteSearchBang.isBuiltIn(s) {
            guard let now = sites?.index.searches.first(where: { $0.id == s.id }) else { return leaveScope(restoring: false) }
            if now != s {
                scope = .site(now)
                applyScope()
            }
        }
        // A chat site turned off (or another profile's Space, with another choice) ends its question, keeping the words.
        if case .ask(let p)? = scope, c.commandBarAskAI != p { return leaveScope(restoring: false) }
        let composing = isComposing
        // "!yt cats": the profile's own shortcuts first, then the built-in bangs. A byte scan when there's no "!".
        let bangWord = Self.bangsEnabled && !isActionsMode && scope == nil && !composing && SiteSearchBang.hasBangWord(q)
        bang = Perf.time("cb.bang") { bangWord ? SiteSearchBang.match(q, own: sites?.index) : nil }
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
            // Never over a bang: "!y" must stay "!y", whatever starts with it.
            guard allowCompletion && !isActionsMode && scope == nil && !composing && !bangWord else { return nil }
            if let m = c.inlineCompletion(for: q) { return m }
            // feedback2: these words mean Send Feedback, not a built-in site ("feed" → Feedly): no site completes them.
            if Self.feedbackWords.contains(q.trimmingCharacters(in: .whitespaces).lowercased()) { return nil }
            guard let s = c.siteCompletion(for: q, history: historyHits) else { return nil }
            site = s.site
            return s.match
        }
        inlineSite = site
        Perf.time("cb.editor") {
            if let editor = input.currentEditor() as? NSTextView, !composing {
                // The completion goes after the caret, selected so typing on replaces it (Chrome, Arc), drawn in the
                // theme's completion ink on its highlight, never the system selection colour (design §7, review #8).
                let r = palette.resolved
                let attributes = inline == nil ? r.textSelectionAttributes : r.inlineCompletionAttributes
                // Set only when they change: setting them redraws the selection (cbfirstkey, ~0.3 ms a keystroke).
                if !(editor.selectedTextAttributes as NSDictionary).isEqual(to: attributes) { editor.selectedTextAttributes = attributes }
                if let m = inline {
                    let start = (q as NSString).length
                    let text = m.text as NSString, shown = editor.string as NSString
                    if shown.length >= start, text.length >= start, shown.substring(to: start) == text.substring(to: start) {
                        // What's typed is already there: only the completion after it changes. Setting the field's whole
                        // value instead ends and restarts the field editor's text (cbfirstkey: ~1 ms of every completing
                        // keystroke). The cell takes the editor's text, as setting the value would have left it.
                        let rest = NSRange(location: start, length: shown.length - start)
                        if shown.substring(with: rest) != text.substring(from: start) {
                            editor.replaceCharacters(in: rest, with: text.substring(from: start))
                        }
                        input.validateEditing()
                    } else {
                        input.stringValue = m.text
                    }
                    let selection = NSRange(location: start, length: text.length - start)
                    if editor.selectedRange() != selection { editor.selectedRange = selection }
                } else if typingAhead {
                    // Typed on into a completion that no longer completes (typeAheadIntoCompletion): what's typed, alone,
                    // as replacing the completion with the character would have left it.
                    let shown = editor.string as NSString, start = (q as NSString).length
                    if shown.length > start, shown.substring(to: start) == q {
                        editor.replaceCharacters(in: NSRange(location: start, length: shown.length - start), with: "")
                        editor.setSelectedRange(NSRange(location: start, length: 0))
                        input.validateEditing()
                    }
                }
            }
        }
        let glyph = Symbols.image(isActionsMode ? "command" : "magnifyingglass", size: 17, weight: .medium)
        if glass.image !== glyph { glass.image = glyph }
        siteCandidate = Perf.time("cb.sitematch") { () -> SiteSearch? in
            // A bang alone ("!yt"): Tab starts its site's search, as "yt" + Tab does. Another bang word: no hint.
            if bangWord { return bang.flatMap { $0.query.isEmpty ? $0.site : nil } }
            guard scope == nil, !isActionsMode, !composing, let sites else { return nil }
            return sites.index.match(q, host: inline?.url ?? inlineSite?.url)
        }
        askCandidate = siteCandidate == nil && scope == nil && !isActionsMode && !composing && bang == nil
            ? c.commandBarAskAI.flatMap { $0.matches(q) ? $0 : nil } : nil
        // The last answer's suggestions stay until the next answer replaces them, in place. Clearing them on every key
        // hid their rows until the answer came (30 ms debounce + the network), then showed them again: rows flickered
        // on each keystroke (owner bug, 0.1.18). They go at once only where no answer will come (an address, one letter,
        // a site search, actions, suggestions off).
        if suggestionQuery != q, !(Self.keepsSuggestions && wantsSuggestions(q)) { suggestions = [] }
        results = Perf.time("cb.results") { composedResults(q, history: historyHits, suggestions: suggestions) }
        // asidepass: "Tab to switch" shows only where Tab would switch to Ask (nothing else of Tab's applies).
        let tabSwitches = !modeToggle.isHidden && !q.isEmpty && !isActionsMode && scope == nil && siteCandidate == nil && askCandidate == nil && inline == nil
        if modeToggle.showsTabHint != tabSwitches { modeToggle.showsTabHint = tabSwitches }
        Perf.time("cb.rows") { reloadRows() }
        #if AIRC_TESTING
        if Self.localHistoryEnabled, !historyHits.isEmpty { onHistoryApplied?(historyHits.count) }
        #endif
        updatePlaceholderVisibility()
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

    /// Test builds can leave bangs out (`AIRC_BANGS=0`), for cbperf's A/B in one binary.
    private static let bangsEnabled: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_BANGS"] != "0"
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

    /// Whether `q` gets suggestions (`suggestionSource`).
    private func wantsSuggestions(_ q: String) -> Bool { suggestionSource(for: q) != nil }

    /// Where `q`'s suggestions come from: the profile's default (C08: an imported default site with its own endpoint too),
    /// or, in a site search, that site's endpoint; nil for an address outside a site search, one letter, a bang, actions,
    /// a chat site, a site without an endpoint, or suggestions off.
    private func suggestionSource(for q: String) -> (source: SearchSuggestions.Source, profileID: String)? {
        guard let c = host, bang == nil, !isActionsMode, q.trimmingCharacters(in: .whitespaces).count >= 2 else { return nil }
        switch scope {
        case nil:
            guard URLRules.normalizeInput(q) == nil else { return nil }
            return c.commandBarSuggestionSource(scope: nil)
        case .site(let s)?:
            guard s.suggestTemplate != nil else { return nil }
            return c.commandBarSuggestionSource(scope: s)
        case .ask?:
            return nil
        }
    }

    /// Test builds can bring back 0.1.26's placement of the prompt's rows (`AIRC_CB_STABLE_ROWS=0`): cbflicker's A/B.
    static let stableRows: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_CB_STABLE_ROWS"] != "0"
        #else
        return true
        #endif
    }()

    /// Test builds can bring back clearing suggestions on every key (`AIRC_CB_KEEP_SUGGESTIONS=0`): cbflicker's A/B.
    static let keepsSuggestions: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_CB_KEEP_SUGGESTIONS"] != "0"
        #else
        return true
        #endif
    }()

    private func requestSuggestions(for q: String) {
        // A site search's query never goes to the profile's engine (only to the site's own endpoint), nor does a bang's.
        guard let source = suggestionSource(for: q) else { return }
        let asked = scope
        SuggestionService.shared.fetch(q, source: source.source, profileID: source.profileID) { [weak self] list in
            guard let self, self.typed == q, self.scope == asked else { return }
            // No suggestions for the new words: the kept ones (for the words before) go.
            if list.isEmpty {
                guard Self.keepsSuggestions, !self.suggestions.isEmpty else { return }
                self.suggestions = []
                self.suggestionQuery = q
                return self.replaceAsyncResults(self.composedResults(q, history: self.historyHits, suggestions: []))
            }
            self.suggestions = list
            self.suggestionQuery = q
            self.replaceAsyncResults(self.composedResults(q, history: self.historyHits, suggestions: list))
        }
    }

    /// The rows for `q`: in a site search, its search and then your pages on that site; otherwise the host's, with the
    /// "Search YouTube" row second while a site matches what's typed.
    private func composedResults(_ q: String, history: [HistoryMatch], suggestions: [String]) -> [CommandResult] {
        guard let c = host else { return [] }
        if instant != nil { return instantRows() }
        if case .site(let s)? = scope { return siteResults(q, site: s, history: history, suggestions: suggestions) }
        if case .ask(let p)? = scope { return askResults(q, provider: p) }
        var rows = c.barCommandResults(for: q, mode: mode, inline: inline, inlineSite: inlineSite, suggestions: suggestions, history: history)
        if let b = bang {
            rows.insert(bangRow(b), at: 0)
            if rows.count > AircMetrics.CommandBar.maxRows { rows.removeLast() }
        } else if let s = siteCandidate {
            // Arc's hint: "Tab", or "Space or Tab" where the profile lets Space start it too.
            let spaces = c.commandBarSiteSearches?.spaceTriggers == true
            var row = CommandResult(title: "Search \(s.name)", subtitle: spaces ? "Press Space or Tab" : "Press Tab", badge: "Site Search",
                                    icon: siteIcon(s), matches: [], action: .run {})
            row.startsScope = .site(s)
            rows.insert(row, at: min(1, rows.count))
            if rows.count > AircMetrics.CommandBar.maxRows { rows.removeLast() }
        }
        addAIRows(&rows, q, host: c)
        return rows
    }

    /// In a site search: the site's search for the query (Return), then the site's own suggestions when it has an endpoint
    /// (C08, an imported engine's), then up to five pages of this profile's history on that site that match it.
    private func siteResults(_ q: String, site s: SiteSearch, history: [HistoryMatch], suggestions: [String]) -> [CommandResult] {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard let url = s.url(for: query) else { return [] }
        var out = [CommandResult(title: query, subtitle: AircCommandText.searchSubtitle(engine: s.name), badge: "Search",
                                 icon: siteIcon(s), matches: [], action: .open(url))]
        if s.suggestTemplate != nil {
            for sug in suggestions.prefix(3) where sug.lowercased() != query.lowercased() {
                guard let u = s.url(for: sug) else { continue }
                out.append(CommandResult(title: sug, subtitle: "", badge: "Search", icon: .symbol("magnifyingglass"), matches: [], action: .open(u)))
            }
        }
        let icons = host?.commandBarShowsSiteIcons == true
        let pagesEnd = out.count + 5
        for h in history where out.count < min(pagesEnd, AircMetrics.CommandBar.maxRows) && s.covers(h.entry.url) {
            guard let page = URL(string: h.entry.url) else { continue }
            let title = h.entry.title.isEmpty ? URLRules.displayURL(h.entry.url) : h.entry.title
            out.append(CommandResult(title: title, subtitle: URLRules.displayHost(h.entry.url), badge: "Open",
                                     icon: icons ? .favicon(image: nil, url: nil, page: h.entry.url) : .monogram(page: h.entry.url),
                                     matches: CommandSearch.score(query, in: title)?.matches ?? [], action: .open(page),
                                     historyURL: h.entry.url))
        }
        return out
    }

    /// A bang's row, first: "Search YouTube for “cats”" (Return opens it); a bang alone, "Search YouTube" (Return or Tab
    /// starts the site's search, as its shortcut and Tab do).
    private func bangRow(_ b: SiteSearchBang.Match) -> CommandResult {
        let label = AircCommandText.searchSubtitle(engine: b.site.name)
        guard let url = b.url else {
            var row = CommandResult(title: label, subtitle: "Press Return or Tab", badge: "Site Search", icon: siteIcon(b.site),
                                    matches: [], action: .run {})
            row.startsScope = .site(b.site)
            return row
        }
        return CommandResult(title: label + " for \u{201C}" + b.query + "\u{201D}", subtitle: "!" + b.keyword, badge: "Search",
                             icon: siteIcon(b.site), matches: [], action: .open(url))
    }

    /// A site's icon on its rows: its favicon (a letter tile until it's cached); a magnifying glass in private windows.
    private func siteIcon(_ s: SiteSearch) -> CommandResult.Icon {
        guard host?.commandBarShowsSiteIcons == true, let home = s.homeURL else { return .symbol("magnifyingglass") }
        return .site(page: home, name: s.name)
    }

    /// An explicit keyboard/hover choice survives late history and suggestions. Untouched selection
    /// follows the new top result. Query edits still reset normally, without changing inline completion.
    private func replaceAsyncResults(_ updated: [CommandResult]) {
        // Instant Links' rows stay until it's done or cancelled; Ask mode lists none (asidepass: late history and
        // suggestions for what was typed in Search drew rows under Ask's panel).
        guard instant == nil, !askMode else { return }
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
    /// ↓ (or ↑ for a negative `d`) as the arrow keys move it (cbflicker's posted arm).
    func moveSelectionForTesting(by d: Int) { select(max(0, min(results.count - 1, selected + d)), userMoved: true) }
    /// Return on the selected row (cbflicker's posted arm).
    func executeSelectedForTesting() { execute() }
    var historySelectionIsExplicitForTesting: Bool { selectedHistoryURL != nil }
    /// The rows on screen, in order (CmdTrustCheck).
    var rowViewsForTesting: [CommandRowView] { Array(rows.prefix(results.count)) }
    /// What the bar would show for what's typed now if every menu command were found and validated now (cbperf).
    /// keyframe2: also without the session's command list, prepared texts, ranking prefilters or remembered inline
    /// targets, so it is the path every key took before.
    func resultsWithoutCommandIndexForTesting() -> [CommandResult] {
        Self.withoutKeyframe2 { ParityCommandCatalog.bypassingIndex { composedResults(typed, history: historyHits, suggestions: suggestions) } }
    }

    /// keyframe2 (cbkey): the rows and the inline completion shown are the ones the path before keyframe2 makes for
    /// what's typed now. Rows as cbperf compares them; "" when they match, else what differs.
    func keyframe2ParityForTesting() -> String {
        func rows(_ r: [CommandResult]) -> [String] {
            r.map { "\($0.title)|\($0.subtitle)|\($0.badge)|\($0.shortcut.joined())|\($0.historyURL ?? "")|\($0.selectionID)" }
        }
        let shown = rows(results), old = rows(resultsWithoutCommandIndexForTesting())
        let inlineNow = host?.inlineCompletion(for: typed)
        let inlineOld = Self.withoutKeyframe2 { host?.inlineCompletion(for: typed) }
        var out = ""
        if shown != old { out += "rows shown \(shown) old \(old)" }
        if inlineNow?.text != inlineOld?.text || inlineNow?.url != inlineOld?.url {
            out += " inline \(inlineNow?.text ?? "-") old \(inlineOld?.text ?? "-")"
        }
        return out
    }

    /// keyframe2: each shown row as drawn (its layer tree, `render(in:)`, 2×), hashed: the A/B arms must give the same.
    func rowImageHashesForTesting() -> [String] {
        rows.prefix(results.count).map { row -> String in
            guard let layer = row.layer, row.bounds.width > 0 else { return "-" }
            let w = Int(row.bounds.width * 2), h = Int(row.bounds.height * 2)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "-" }
            ctx.scaleBy(x: 2, y: 2)
            layer.render(in: ctx)
            guard let data = ctx.data else { return "-" }
            var hash: UInt64 = 0xcbf29ce484222325
            let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            for i in 0..<(w * h * 4) { hash = (hash ^ UInt64(bytes[i])) &* 0x100000001b3 }
            return String(hash, radix: 16)
        }
    }

    static func withoutKeyframe2<T>(_ body: () -> T) -> T {
        let p = CommandSearch.prefilters, m = InlineCompletion.memoizesTargets, g = CommandSearch.memoizesPages
        CommandSearch.prefilters = false
        CommandSearch.memoizesPages = false
        InlineCompletion.memoizesTargets = false
        defer { CommandSearch.prefilters = p; CommandSearch.memoizesPages = g; InlineCompletion.memoizesTargets = m }
        return body()
    }
    #endif

    private func reloadRows() {
        #if AIRC_TESTING
        defer { onRowsReloaded?(self) }
        #endif
        userSelectedResult = nil
        selected = 0
        // Typing (and late results) put the top match first again; the pointer has to move to pick another row.
        restingPointer = NSEvent.mouseLocation
        while rows.count < results.count { rows.append(makeRow()) }
        let icons = host?.commandBarShowsSiteIcons == true
        CommandRowView.engineFavicons = icons ? host?.commandBarFaviconDatabase : nil
        // Each row restyles only what differs from what it shows (CommandRowView.changes, cbrows): from key to key most
        // rows keep their icon, seal, subtitle and kind; a row showing exactly its result is left as it is. Rows stay
        // in their places (the subviews' order is VoiceOver's, and a row under the pointer keeps its hover).
        Perf.time("cb.configure") { for (r, res) in zip(rows, results) { r.configure(res) } }
        // Rows beyond the results stay, hidden, for the next keystroke or opening.
        for (i, r) in rows.enumerated() where r.isHidden != (i >= results.count) { r.isHidden = i >= results.count }
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
        // cmdfast: a key before the deferred editing session started starts it now, so everything below (and the key's
        // own way on to the field) runs as it would have with the session started in ⌘T's frame.
        if sessionPending, beginPendingSession() { Self.sessionStats.startedByKey += 1 }
        guard let editor = input.currentEditor() as? NSTextView, window?.firstResponder === editor, !editor.hasMarkedText()
        else { return false }
        // ⇧↵ (P07c): Instant Links, or a normal search of what's typed where it's off.
        if event.keyCode == 36 || event.keyCode == 76, mods == .shift {
            #if AIRC_TESTING
            keyLog.append("shiftReturn")
            #endif
            shiftReturn()
            return true
        }
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
            if askMode { submitAsk(); return true }
            execute()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // In a site search Tab stays in the field.
            if scope != nil { return true }
            // asidepass: from Ask, Tab always goes back to Search (what's typed stays).
            if askMode { setAskMode(false); return true }
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
            if let p = askCandidate {
                enterScope(.ask(p))
                return true
            }
            if inline != nil {
                textView.moveToEndOfDocument(nil)
                typed = input.stringValue
                update(allowCompletion: false)
                return true
            }
            // Nothing else for Tab: it switches to Ask, keeping what's typed.
            if !modeToggle.isHidden, !isActionsMode { setAskMode(true); return true }
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
        if instant != nil { return cancelInstant(restore: true) }
        if askMode { return setAskMode(false) }
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
        if r.startsInstantLinks { return startInstantLinks() }
        // Chosen: now its icon may come from the network (rows never ask for one while you type).
        CommandRowView.fetchIcon(of: r)
        let newTab = mode == .newTab || r.opensInNewTab
        guard case .run = r.action else {
            host?.closeCommandBar()
            host?.performCommand(r.action, newTab: newTab, typed: !r.opensInNewTab)
            return
        }
        // A command (Ask This Page…, Ask Airc to…, a menu's): the page gets the keyboard back only if the command didn't
        // give it to a field of its own. The page taking it after the command had focused its field (Chromium focuses
        // late) left the keys going nowhere, each one beeping (owner bug, 0.1.26: "ask page").
        host?.closeCommandBar(focusingPage: false)
        host?.performCommand(r.action, newTab: newTab, typed: !r.opensInNewTab)
        host?.focusPageUnlessTaken()
    }

    // MARK: Ask mode (asidepass, CommandBarAsk.swift)

    static let searchGlyph = Symbols.image("magnifyingglass", size: 17, weight: .medium)
    static let askGlyph = Symbols.image("sparkles", size: 17, weight: .medium)

    /// Search ↔ Ask. What's typed stays; Ask's panel is made on its first use.
    func setAskMode(_ on: Bool, refresh: Bool = true) {
        guard on != askMode, !on || askWindow != nil else { return }
        if on, scope != nil { leaveScope(restoring: false) }
        if on, instant != nil { cancelInstant(restore: false) }
        askMode = on
        modeToggle.ask = on
        if on, askPanel == nil {
            let a = CommandBarAskPanel(theme: palette.resolved)
            a.model.controller = askWindow
            panel.addSubview(a)
            askPanel = a
        }
        if on, let c = askWindow, let a = askPanel {
            a.model.controller = c
            a.model.spaceID = c.currentSpaceID
            a.model.theme = palette.resolved
            a.model.openTask = { [weak self, weak c] t in
                guard let c else { return }
                self?.host?.closeCommandBar(focusingPage: false)
                AgentTasksPage.openTask(t.id, in: c)
            }
            a.model.showAll = { [weak self, weak c] in
                guard let c else { return }
                self?.host?.closeCommandBar(focusingPage: false)
                AgentTasksPage.open(in: c)
            }
            if a.model.attached.isEmpty, mode == .editURL, let page = AgentAskContext.shownPage(of: c) { a.model.attached = [page] }
        }
        if modeToggle.showsTabHint { modeToggle.showsTabHint = false }
        applyPlaceholder()
        NSAccessibility.post(element: modeToggle, notification: .valueChanged)
        guard refresh else { return }
        if on { updateAsk() } else { update(allowCompletion: false) }
    }

    /// Ask mode's "update": no rows, the panel's height for this Space.
    private func updateAsk() {
        if !results.isEmpty { results = []; reloadRows() }
        updatePlaceholderVisibility()
        if let sv = superview { layoutIn(sv.bounds, sidebarFrame: sidebarFrame, contentFrame: contentFrame) }
    }

    /// Return in Ask: the task starts and its view opens.
    private func submitAsk() {
        guard let c = askWindow else { return }
        let text = input.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let attached = askPanel?.model.attached ?? []
        host?.closeCommandBar(focusingPage: false)
        Self.startAgentTask(text, attached: attached, in: c)
    }

    #if AIRC_TESTING
    var modeToggleForTesting: CommandBarModeToggle { modeToggle }
    #endif

    // MARK: Ask AI (P07b)

    /// "gpt" + Tab: the question, opening on the chat site in a new tab (whatever opened the bar).
    private func askResults(_ q: String, provider p: AskAIProvider) -> [CommandResult] {
        guard let url = AskAIRoute.url(p, q) else { return [] }
        return [askRow(q.trimmingCharacters(in: .whitespacesAndNewlines), subtitle: "Ask \(p.name) in a new tab", provider: p, url: url)]
    }

    /// The plain bar's Ask row: under the search row and the row after it (↓↓), as the feedback asked.
    static let askRowIndex = 2
    /// agentpanel2's row (the Airc Agent panel's own wording, "Ask Airc to…").
    static let agentRowTitle = "Ask Airc to…"

    private func askRow(_ title: String, subtitle: String, provider p: AskAIProvider, url: URL) -> CommandResult {
        var row = CommandResult(title: title, subtitle: subtitle, badge: "Ask", icon: siteIcon(p.siteSearch), matches: [], action: .open(url))
        row.opensInNewTab = true
        return row
    }

    /// The plain bar's AI rows: "Ask ChatGPT · Press Tab" for "gpt" (where no site search matches); Instant Links' hint
    /// under the search row (⇧↵, only while it can run); for a prompt (`AskAIProvider.looksLikePrompt`), Arc's "Ask GPT
    /// What You Typed": "Ask Claude", third (↓↓ from the search row), above your history (askai).
    private func addAIRows(_ rows: inout [CommandResult], _ q: String, host c: CommandBarHost) {
        let limit = AircMetrics.CommandBar.maxRows
        if let p = askCandidate {
            var row = CommandResult(title: "Ask \(p.name)", subtitle: "Press Tab", badge: "Ask", icon: siteIcon(p.siteSearch),
                                    matches: [], action: .run {})
            row.startsScope = .ask(p)
            rows.insert(row, at: min(1, rows.count))
        }
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if bang == nil, Self.isInstantQuery(text), c.commandBarInstantLinks != nil,
           let i = rows.firstIndex(where: { $0.badge == "Search" && $0.title == text }) {
            let n = InstantLinks.count(in: text)
            var row = CommandResult(title: n == 1 ? "Open the Top Result" : "Open the Top \(n) Results", subtitle: "Instant Links",
                                    badge: "Open", icon: .symbol("sparkles"), matches: [], action: .run {}, shortcut: ["⇧", "↩"])
            row.startsInstantLinks = true
            rows.insert(row, at: i + 1)
        }
        // A prompt's rows: while what's typed looks like a prompt, and (cbflicker2) on until the words they showed for
        // are taken back, so a guess that flips on a key doesn't make them come and go.
        let guessed = Perf.time("cb.askai") { scope == nil && askCandidate == nil && bang == nil && AskAIProvider.looksLikePrompt(text) }
        var prompt = guessed
        if Self.stableRows, scope == nil, askCandidate == nil, bang == nil {
            if let shown = promptShownFor, !text.isEmpty, text.hasPrefix(shown) { prompt = true }
            if !prompt { promptShownFor = nil } else if promptShownFor.map({ !text.hasPrefix($0) }) ?? true { promptShownFor = text }
        }
        // Where they go: two arrows down (askai), the agent's right under it.
        let askAt = Self.askRowIndex
        var askShown = false
        if prompt, let p = c.commandBarAskAI, let url = AskAIRoute.url(p, text) {
            askShown = true
            rows.insert(askRow("Ask \(p.name)", subtitle: text, provider: p, url: url), at: min(askAt, rows.count))
        }
        // agentpanel2: "Ask Airc to…" (the Airc Agent does it in this profile), right under the Ask row (↓↓↓), or third.
        // With no key it opens the panel at its setup with the task in its field (cbflicker2).
        Perf.time("cb.agentrow") {
            guard prompt, let ask = c.commandBarAgent else { return }
            let at = askShown ? rows.firstIndex { $0.badge == "Ask" && $0.subtitle == text }.map { $0 + 1 } ?? askAt : askAt
            rows.insert(CommandResult(title: Self.agentRowTitle, subtitle: text, badge: "Agent", icon: .symbol("sparkles"), matches: [],
                                      action: .run { ask(text) }), at: min(at, rows.count))
        }
        if rows.count > limit { rows.removeLast(rows.count - limit) }
    }

    // MARK: Instant Links (P07c)

    private enum InstantState {
        /// Finding pages for `query`; Return searches it now.
        case resolving(Task<Void, Never>, query: String, search: URL?, engine: String)
        /// What will open: Return or ⇧↵ opens it, Esc goes back.
        case preview(InstantLinksPlan, engine: String)
    }

    /// Text Instant Links can look for: words, not an address or a command.
    static func isInstantQuery(_ q: String) -> Bool {
        !q.isEmpty && !q.hasPrefix("/") && URLRules.normalizeInput(q) == nil
    }

    /// ⇧↵: open what the preview shows; else find the pages; where Instant Links is off (no Apple Intelligence, the
    /// switch, a private window, a site search), a normal search of what's typed.
    func shiftReturn() {
        switch instant {
        case .preview(let plan, _)?: return openInstantPlan(plan.links)
        case .resolving?: return
        case nil: break
        }
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if scope == nil, bang == nil, Self.isInstantQuery(text), host?.commandBarInstantLinks != nil { return startInstantLinks() }
        if scope == nil, let i = results.firstIndex(where: { $0.badge == "Search" && $0.title == text }) { select(i) }
        execute()
    }

    /// Looks for the pages (AircKit's InstantLinksResolver) while the bar shows "Finding the best result…".
    func startInstantLinks() {
        guard instant == nil, scope == nil, !isComposing, let ctx = host?.commandBarInstantLinks else { return }
        let q = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isInstantQuery(q) else { return }
        if inline != nil {
            input.stringValue = typed
            inline = nil
            inlineSite = nil
        }
        let task = Task { @MainActor [weak self] in
            let outcome = await ctx.resolver.resolve(q, search: ctx.search)
            guard let self, !Task.isCancelled, case .resolving(_, let asked, _, _)? = self.instant, asked == q else { return }
            InstantLinksFeature.lastOutcome = outcome
            self.finishInstant(outcome)
        }
        instant = .resolving(task, query: q, search: ctx.search.url(for: q), engine: ctx.search.name)
        results = instantRows()
        reloadRows()
        NSAccessibility.post(element: input, notification: .announcementRequested,
                             userInfo: [.announcement: "Finding the best result", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func finishInstant(_ outcome: InstantLinksOutcome) {
        guard case .resolving(_, _, _, let engine)? = instant else { return }
        switch outcome {
        case .open(let plan):
            instant = .preview(plan, engine: engine)
            results = instantRows()
            reloadRows()
            let n = plan.links.count
            NSAccessibility.post(element: input, notification: .announcementRequested,
                                 userInfo: [.announcement: n == 1 ? "\(plan.links[0].title). Return opens it" : "\(n) results. Return opens them",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        case .search(let url, _):
            instant = nil
            guard let url else { return update(allowCompletion: false) }
            host?.closeCommandBar()
            host?.performCommand(.open(url), newTab: mode == .newTab, typed: true)
        case .cancelled:
            instant = nil
            update(allowCompletion: false)
        }
    }

    /// Esc, typing, the bar closing: the search stops (nothing opens) and, with `restore`, the rows come back.
    private func cancelInstant(restore: Bool) {
        guard let state = instant else { return }
        if case .resolving(let task, _, _, _) = state { task.cancel() }
        instant = nil
        if restore { update(allowCompletion: false) }
    }

    private func openInstantPlan(_ links: [InstantLink]) {
        let newTab = mode == .newTab
        host?.closeCommandBar()
        host?.openInstantLinks(Array(links.prefix(InstantLinks.maxLinks)), newTab: newTab)
    }

    /// While finding: one row (Return searches now). The preview: "Open 3 Results" (⇧↵) over the pages (each opens on its
    /// own), then the normal search.
    private func instantRows() -> [CommandResult] {
        let icons = host?.commandBarShowsSiteIcons == true
        switch instant {
        case .resolving(_, let q, let search, let engine)?:
            let n = InstantLinks.count(in: q)
            return [CommandResult(title: n == 1 ? "Finding the best result…" : "Finding the top \(n) results…",
                                  subtitle: "Instant Links · \(engine) · Esc to cancel", badge: "Search", icon: .symbol("sparkles"),
                                  matches: [], action: search.map(CommandResult.Action.open) ?? .run {})]
        case .preview(let plan, let engine)?:
            var rows: [CommandResult] = []
            let links = Array(plan.links.prefix(InstantLinks.maxLinks))
            if links.count > 1 {
                let newTab = mode == .newTab
                rows.append(CommandResult(title: "Open \(links.count) Results", subtitle: links.map(\.host).joined(separator: " · "),
                                          badge: "Open All", icon: .symbol("square.stack"), matches: [],
                                          action: .run { [weak host = self.host] in host?.openInstantLinks(links, newTab: newTab) },
                                          shortcut: ["⇧", "↩"]))
            }
            for l in links {
                // A Google result opens through Google's redirect: its site is what Google printed under it.
                let subtitle = l.displaySite.map { "\($0) · as shown by \(engine)" } ?? l.host
                let page = l.isRedirect ? "https://\(l.host)/" : l.url.absoluteString
                rows.append(CommandResult(title: l.title, subtitle: subtitle, badge: "Open",
                                          icon: icons ? .favicon(image: nil, url: nil, page: page) : .monogram(page: page),
                                          matches: [], action: .open(l.url), shortcut: links.count == 1 ? ["⇧", "↩"] : []))
            }
            rows.append(CommandResult(title: plan.query, subtitle: "Search \(engine) instead", badge: "Search",
                                      icon: .symbol("magnifyingglass"), matches: [], action: .open(plan.searchURL)))
            return rows
        case nil:
            return []
        }
    }

    #if AIRC_TESTING
    /// Checks: "finding", "preview" or "".
    var instantStateLabel: String {
        switch instant {
        case .resolving?: "finding"
        case .preview?: "preview"
        case nil: ""
        }
    }
    var instantPreview: InstantLinksPlan? {
        if case .preview(let p, _)? = instant { return p }
        return nil
    }
    /// The marketing shot: a preview as the resolver would have made it.
    func showInstantPreviewForTesting(_ plan: InstantLinksPlan, engine: String) {
        cancelInstant(restore: false)
        instant = .preview(plan, engine: engine)
        results = instantRows()
        reloadRows()
    }
    #endif
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
/// The bar's field editor: typing on into the inline completion keeps it (CommandBarView.typeAheadIntoCompletion).
final class CommandBarFieldEditor: NSTextView {
    weak var bar: CommandBarView?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = string as? String, let bar, bar.typeAheadIntoCompletion(text, replacementRange: replacementRange, in: self) {
            return
        }
        Perf.time("cb.insert") { super.insertText(string, replacementRange: replacementRange) }
    }
}

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
        // One typed character: the text system's first insert loads AppKit's undo-coalescing strings from disk and
        // sets up its typing state, ~1 ms that otherwise lands on the bar's first keystroke (cbperf3).
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.undoManager?.removeAllActions()
        }
        w.makeFirstResponder(nil)
        w.close()
    }

    private static var completionDone = false
    /// Hands the warm-up window's field its own editor: the bar's kind (TextKit 1, `CommandBarView.makeFieldEditor`).
    private final class EditorSource: NSObject, NSWindowDelegate {
        let editor = CommandBarView.makeFieldEditor()
        func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { client is NSTextField ? editor : nil }
    }

    /// cbperf4: what the first keystroke did for the first time in the bar's own kind of editor, once per process off
    /// screen: the bar's field editor is TextKit 1 (`run()`'s plain field gets AppKit's TextKit 2 one), so its first
    /// typesetting (NSATSTypesetter, the field font's glyphs), the first inline completion written after the caret, its
    /// completion-ink selection attributes and the selection itself all landed on the first key.
    static func runCompletion(font: NSFont, attributes: [NSAttributedString.Key: Any]) {
        guard !completionDone else { return }
        completionDone = true
        let source = EditorSource()
        let w = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 480, height: 40), styleMask: .borderless,
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.delegate = source
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        field.contentType = .URL
        field.font = font
        w.contentView?.addSubview(field)
        w.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView, editor === source.editor {
            editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
            // As CommandBarView.update writes a completion: the rest after the caret, selected, in the completion ink.
            editor.selectedTextAttributes = attributes
            editor.replaceCharacters(in: NSRange(location: 1, length: 0), with: "irc.example.com")
            field.validateEditing()
            editor.selectedRange = NSRange(location: 1, length: 15)
            if let lm = editor.layoutManager, let tc = editor.textContainer { lm.ensureLayout(for: tc) }
            editor.undoManager?.removeAllActions()
        }
        w.makeFirstResponder(nil)
        w.delegate = nil
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
        let letter = SiteMonogram.letter(for: name)
        let size = r.height * 11 / 18
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white])
        colors[SiteMonogram.colorIndex(for: name, count: colors.count)].setFill()
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
    /// The pointer entered or moved over the row; true: a check's stand-in for a real move (setHoveredForTesting).
    var onHover: ((Bool) -> Void)?
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
    /// The engine profile's favicon database the rows read icons from (SiteIcons), set by the bar for its window before it
    /// configures them; nil in private windows and on WebKit.
    static var engineFavicons: URL?
    /// The verified mark after the title of a row on Airc's list of official sites (OfficialSites).
    private let seal = CALayer()
    private var sealImage: NSImage?
    /// The row's kind ("Website", "Open Tab"…) at its end while it isn't selected.
    private let kindLabel = AircFadingLabel(style: AircFont.urlField)
    private var shownKind: NSAttributedString?
    private(set) var trust: OfficialSites.Site?
    /// A `.favicon` row with no page to letter a tile from shows a globe.
    private var showsGlobe = false
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
        for v in [icon, siteIcon, emoji, title, subtitle, kindLabel, action, removeButton] as [NSView] { addSubview(v) }
        kindLabel.lineBreakMode = .byClipping
        seal.actions = LayerImage.noActions
        seal.isHidden = true
        seal.contentsGravity = .resizeAspect
        layer?.addSublayer(seal)
        removeButton.isHidden = true
        removeButton.onPress = { [weak self] in self?.onRemove?() }
        siteIcon.isHidden = true
        tile.actions = LayerImage.noActions
        tile.isHidden = true
        siteIcon.layer?.addSublayer(tile)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// The official-site seal made and drawn once at idle (`CommandBarView.prewarmEditing`). Made cold, its SF Symbol
    /// (CoreUI's glyph lookup, the SVG parse, the tint and the first raster) took ~1–1.5 ms of the first keystroke whose
    /// rows show an official site (cbperf3). The symbol and tint are cached (LayerImage); this only moves when.
    /// The symbols rows show besides the commands' own (search, Ask AI, Instant Links, a page with no icon).
    static let rowSymbols: Set<String> = ["magnifyingglass", "sparkles", "square.stack", "globe"]

    /// A row icon's symbol (FaviconView: 14 pt semibold in the ink) made and rasterised as a row would show it.
    static func prewarmSymbol(_ name: String, ink: NSColor, scale: CGFloat) {
        guard let img = LayerImage.symbol(name, size: 14, weight: .semibold, color: ink) else { return }
        _ = img.layerContents(forContentsScale: img.recommendedLayerContentsScale(scale))
    }

    func prewarmArt(scale: CGFloat) {
        guard let p = palette,
              let img = LayerImage.symbol("checkmark.seal.fill", size: 12, weight: .semibold, color: p.resolved.accent.nsColor)
        else { return }
        var rect = NSRect(origin: .zero, size: img.size)
        _ = img.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
    }

    func configure(_ r: CommandResult) {
        let parts = changes(to: r)
        let old = result
        result = r
        if parts.contains(.page) || old == nil { trust = r.trust }
        if !parts.isEmpty { restyle(parts) }
        if old?.historyURL != r.historyURL { updateRemoveButton() }
    }

    /// The parts of the row that showing `r` instead of the result it shows changes (cbrows: a keystroke restyles only
    /// those; most rows keep their icon, seal, subtitle and kind from key to key). Everything when it shows nothing yet
    /// or its theme changed since.
    struct Parts: OptionSet {
        let rawValue: Int
        static let title = Parts(rawValue: 1), subtitle = Parts(rawValue: 2), kind = Parts(rawValue: 4)
        static let shortcut = Parts(rawValue: 8), icon = Parts(rawValue: 16), page = Parts(rawValue: 32)
        static let badge = Parts(rawValue: 64)
        static let all = Parts(rawValue: 127)
    }

    func changes(to r: CommandResult) -> Parts {
        // Every palette change restyles the whole row (`palette`'s didSet), so a row styled once is in its theme.
        guard let old = result, palette != nil, shownTheme != nil else { return .all }
        var parts: Parts = []
        // The trust mark and a trusted row's subtitle come from the badge and the page.
        if old.page != r.page || old.badge != r.badge { parts.insert([.page, .subtitle]) }
        if old.title != r.title || old.matches != r.matches { parts.insert(.title) }
        if old.subtitle != r.subtitle || (trust != nil && old.title != r.title) { parts.insert(.subtitle) }
        if old.badge != r.badge { parts.insert(.badge) }
        if old.kind != r.kind { parts.insert(.kind) }
        if old.shortcut != r.shortcut { parts.insert(.shortcut) }
        // A globe is a favicon not found when it was configured: looked up again, as a full restyle would.
        if showsGlobe || !CommandResult.sameIcon(old.icon, r.icon) { parts.insert(.icon) }
        return parts
    }

    /// The ✕ shows on a history row under the pointer (the row's other trailing parts move left of it).
    private func updateRemoveButton() {
        let show = isHovered && !isHidden && result?.historyURL != nil
        // keyframe2: only while it shows (setting it redraws the button, hidden or not: up to 9 hidden redraws a key).
        if show || !CommandBarView.keyframe2 { removeButton.palette = palette }
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
    /// The subtitle has no right-to-left script (natural alignment puts it at the left edge, whatever the width).
    private var subtitleIsLTR = true
    private var shownTheme: ResolvedTheme?

    private func restyle(_ parts: Parts = .all) {
        guard let p = palette, let r = result else { return }
        let theme = p.resolved
        if parts == .all {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = isSelected ? p.panelSelection.cgColor : NSColor.clear.cgColor
            CATransaction.commit()
        }
        var changed = false
        if parts.contains(.title) {
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
        }
        if parts.contains(.subtitle) {
            let sub = NSAttributedString(string: TextLimits.clip(subtitleText(r)), attributes: theme.commandRowSubtitleAttributes)
            if shownSubtitle.map({ !$0.isEqual(to: sub) }) ?? true {
                shownSubtitle = sub
                subtitle.attributedStringValue = sub
                subtitleIsLTR = !sub.string.unicodeScalars.contains { $0.value >= 0x0590 }
                changed = true
            }
        }
        // keyframe2: the action shows only on the selected row; setting its title on the others redrew hidden views.
        if action.title != r.badge, isSelected || !CommandBarView.keyframe2 { action.title = r.badge; changed = true }
        // The kind shows where the action doesn't: on rows that aren't selected and aren't showing their ✕.
        if parts.contains(.kind) || parts.contains(.badge) {
            let kindText = isSelected && !r.badge.isEmpty ? "" : r.kind
            let kind = NSAttributedString(string: kindText, attributes: theme.commandRowSubtitleAttributes)
            if shownKind.map({ !$0.isEqual(to: kind) }) ?? true {
                shownKind = kind
                kindLabel.attributedStringValue = kind
                kindLabel.isHidden = kindText.isEmpty
                changed = true
            }
        }
        if parts.contains(.page) {
            let sealShown = trust != nil
            if seal.isHidden == sealShown {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                seal.isHidden = !sealShown
                CATransaction.commit()
                changed = true
            }
            if sealShown, let img = LayerImage.symbol("checkmark.seal.fill", size: 12, weight: .semibold, color: theme.accent.nsColor),
               img !== sealImage {
                sealImage = img
                LayerImage.set(img, on: seal, in: self)
            }
        }
        let themeChanged = shownTheme != theme
        shownTheme = theme
        if themeChanged { action.theme = theme }
        let actionSelected = isSelected && !r.badge.isEmpty
        if action.isSelected != actionSelected { action.isSelected = actionSelected; changed = true }
        if parts.contains(.shortcut) || themeChanged {
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
        }
        guard parts.contains(.icon) else {
            if changed || themeChanged { needsLayout = true }
            return
        }
        // No row asks the network for an icon while you type, so the sites shown never learn what you might open: an
        // icon in memory, in the disk caches or in the engine profile's favicon database (SiteIcons), and the site's
        // letter tile until then; the network only once the row is chosen (`fetchIcon`). Never a blank square.
        var tiled = false, globe = false
        defer { showsGlobe = globe }
        switch r.icon {
        case .favicon(let image, let url, let page):
            emoji.isHidden = true
            let key = image == nil ? url ?? page.flatMap(FaviconCache.guess(for:)) : nil
            if let img = image ?? FaviconCache.shared.cached(key) ?? page.flatMap({ SiteIcons.shared.cached(page: $0) }) {
                icon.isHidden = false
                icon.set(image: img, url: nil, fallbackPage: nil, palette: p)
            } else if let page, let name = SiteMonogram.name(forPage: page) {
                tiled = true
                showSiteIcon(page: page, name: name, key: key, lookups: true, palette: p)
            } else {
                icon.isHidden = false
                icon.set(image: nil, url: nil, fallbackPage: nil, palette: p, symbol: "globe")
                globe = true
            }
        case .site(let page, let name):
            tiled = true
            showSiteIcon(page: page, name: name, key: FaviconCache.guess(for: page), lookups: true, palette: p)
        case .monogram(let page):
            tiled = true
            showSiteIcon(page: page, name: SiteMonogram.name(forPage: page) ?? page, key: nil, lookups: false, palette: p)
        case .symbol(let s):
            icon.isHidden = false
            emoji.isHidden = true
            icon.set(image: nil, url: nil, fallbackPage: nil, palette: p, symbol: s)
        case .emoji(let e):
            icon.isHidden = true
            emoji.isHidden = false
            if emoji.stringValue != e { emoji.stringValue = e }
        }
        if !tiled {
            showTile(nil)
            if !siteIcon.isHidden { siteIcon.isHidden = true }
        }
        if changed || themeChanged { needsLayout = true }
    }

    /// A trusted row's subtitle: the real host (or, when the title is the host, the site's name) and the list's label,
    /// "chromewebstore.google.com · Supported in Airc". Others: the row's own.
    private func subtitleText(_ r: CommandResult) -> String {
        guard let t = trust, let host = r.page.flatMap({ URLComponents(string: $0)?.host?.lowercased() }) else { return r.subtitle }
        let titleIsHost = r.title.lowercased().hasPrefix(host) || r.title.lowercased().hasPrefix(URLRules.displayHost("https://" + host))
        return (titleIsHost ? t.name : host) + " · " + t.label
    }

    /// A site's icon in `siteIcon`: the caches' copy if it's in memory, else its letter tile at once and the icon when
    /// a disk cache or the engine's database has it (`lookups`; a private window's rows keep the tile).
    private func showSiteIcon(page: String, name: String, key: String?, lookups: Bool, palette p: Palette) {
        icon.isHidden = true
        siteIcon.isHidden = false
        emoji.isHidden = true
        // The row asks the caches itself and hands the favicon view only finished images: the view's own request isn't
        // cleared by a cache hit, so a slower icon asked for by the row's previous site could land on this one ("sp"
        // shows Spiegel, "spot" Spotify). The letter tile shows until the icon is there.
        if lookups, let img = FaviconCache.shared.cached(key) ?? SiteIcons.shared.cached(page: page) {
            siteIcon.set(image: img, url: nil, fallbackPage: nil, palette: p)
            showTile(nil)
            return
        }
        siteIcon.set(image: nil, url: nil, fallbackPage: nil, palette: p)
        Perf.time("cb.tile") { showTile(LetterTile.image(for: name)) }
        let token = (key ?? "") + "|" + page
        guard lookups, tileKey != token else { return }
        tileKey = token
        let database = Self.engineFavicons
        let land: (NSImage?) -> Bool = { [weak self] img in
            guard let self, self.tileKey == token else { return true }
            guard let img, let palette = self.palette else { return false }
            self.siteIcon.set(image: img, url: nil, fallbackPage: nil, palette: palette)
            self.showTile(nil)
            return true
        }
        FaviconCache.shared.stored(key) { img in
            if land(img) { return }
            SiteIcons.shared.lookup(page: page, database: database) { _ = land($0) }
        }
    }

    #if AIRC_TESTING
    /// What the row's icon shows now (CmdTrustCheck): "image", "tile", "symbol", "emoji" or "placeholder".
    var iconStateForTesting: String {
        if !emoji.isHidden { return "emoji" }
        if !siteIcon.isHidden { return tile.isHidden ? (siteIcon.shownImage != nil ? "image" : "placeholder") : "tile" }
        if case .symbol? = result?.icon { return "symbol" }
        if icon.isHidden { return "none" }
        return icon.shownImage == nil ? "placeholder" : (showsGlobe ? "symbol" : "image")
    }
    var kindForTesting: String { kindLabel.isHidden ? "" : kindLabel.stringValue }
    var subtitleForTesting: String { subtitle.stringValue }
    var sealShownForTesting: Bool { !seal.isHidden && sealImage != nil }
    #endif

    /// A chosen row's icon, from the network if no cache has it: the site is being opened now.
    static func fetchIcon(of r: CommandResult) {
        let key: String?
        switch r.icon {
        case .favicon(let image, let url, let page): key = image == nil ? url ?? page.flatMap(FaviconCache.guess(for:)) : nil
        case .site(let page, _): key = FaviconCache.guess(for: page)
        case .monogram, .symbol, .emoji: key = nil
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
        if !kindLabel.isHidden, removeButton.isHidden {
            let w = ceil(Self.cellWidth(kindLabel))
            x -= w
            kindLabel.frame = NSRect(x: x, y: (h - 16) / 2 + 1, width: w, height: 16)
            x -= 12
        } else if !kindLabel.isHidden {
            kindLabel.frame = .zero
        }
        let right = x - AircMetrics.Row.titleFadeGap
        let sealW: CGFloat = seal.isHidden ? 0 : 18
        let tw = min(Self.cellWidth(title), (right - 46 - sealW) * (subtitle.stringValue.isEmpty ? 1 : 0.62))
        title.frame = NSRect(x: 46, y: (h - 18) / 2, width: max(0, tw), height: 18)
        if !seal.isHidden {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            seal.frame = NSRect(x: title.frame.maxX + 4, y: (h - 13) / 2, width: 13, height: 13)
            CATransaction.commit()
        }
        let sx = title.frame.maxX + sealW + 10
        var sw = max(0, right - sx)
        // keyframe2: the subtitle's width followed the title's, so a new title made every subtitle redraw its unchanged
        // text (a resized layer redisplays). While its text fits (no fade either way) and runs left to right, the width
        // stays at what the row has from the title's start: the same pixels, and moving a layer draws nothing.
        if CommandBarView.keyframe2, subtitleIsLTR, subtitle.textWidth <= sw - 2 { sw = max(sw, right - 46 - sealW) }
        subtitle.frame = NSRect(x: sx, y: (h - 16) / 2 + 1, width: sw, height: 16)
    }

    /// A label's width as `sizeToFit` would make it (its cell: the text and 2 pt each side). keyframe: from the text width
    /// the label measures for its own layout anyway, so a changed title or kind is typeset once, not twice, per key.
    static func cellWidth(_ label: AircFadingLabel) -> CGFloat {
        CommandBarView.keyframe ? label.textWidth + 4 : label.fittingCellSize.width
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // `.inVisibleRect` follows the row's visible rect by itself: one area for the row's life (keyframe), not a new one
        // whenever AppKit asks after a geometry change.
        if CommandBarView.keyframe, trackingAreas.count == 1 { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(false)
    }
    /// A pointer that rested on the row when it appeared picks it once it moves (the bar decides, see `restingPointer`).
    override func mouseMoved(with event: NSEvent) {
        if isHovered, !isSelected { onHover?(false) }
    }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    func clearHover() { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    #if AIRC_TESTING
    /// ParityP03bCheck: the pointer over the row (posted mouse moves never reach tracking areas).
    func setHoveredForTesting(_ on: Bool) {
        isHovered = on
        if on { onHover?(true) }
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
        // C08: Arc's per-profile "Include search engine suggestions".
        guard profile.includesSearchSuggestions else { return nil }
        // P07d: a site search made the default asks the engine nothing (its own endpoint, if any, is
        // `commandBarSuggestionSource`'s).
        guard profile.defaultSearch.site == nil else { return nil }
        return (profile.searchEngine, profile.id)
    }

    /// C08: an imported site search's own endpoint (Chromium's `suggest_url`) while it's the default or the search in
    /// progress, under the built-in engines' rules: off with Settings › Privacy's switch or the profile's "Include search
    /// engine suggestions", one cookie-less session per profile.
    func commandBarSuggestionSource(scope site: SiteSearch?) -> (source: SearchSuggestions.Source, profileID: String)? {
        guard app?.settings.values.suggestionsEnabled ?? true else { return nil }
        let profile = store.profile(ofSpace: currentSpaceID)
        guard profile.includesSearchSuggestions else { return nil }
        if let site { return site.suggestTemplate == nil ? nil : (.site(site), profile.id) }
        switch profile.defaultSearch {
        case .engine(let e): return (.engine(e), profile.id)
        case .site(let s): return s.suggestTemplate == nil ? nil : (.site(s), profile.id)
        }
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
        Self.commandMemo = nil
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
        if let source = commandBarSuggestionSource(scope: nil) {
            // After this frame's commit: the first opening per profile makes its URLSession here (milliseconds). Not
            // `async`: the main queue drains before the run loop's Core Animation commit, a 2 ms timer only after it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) {
                SuggestionService.shared.prewarm(source: source.source, profileID: source.profileID)
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
        // cbperf4: this opening's commands (and, a timer later, their prepared texts: `sessionCommands`) right after its
        // commit, while nothing is typed yet, so the first keystroke ranks them as the later ones do instead of making
        // them in its own frame. A timer, not `async`: the main queue drains before the commit.
        if CommandBarView.firstKeyWarm, CommandBarView.keyframe2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self, weak bar] in
                guard let self, let bar, self.commandBar === bar, bar.query.isEmpty else { return }
                _ = self.sessionCommands()
            }
        }
    }

    func closeCommandBar() { closeCommandBar(focusingPage: true) }

    func closeCommandBar(focusingPage: Bool) {
        guard let bar = commandBar else { return }
        commandBar = nil
        Self.commandMemo = nil
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
        if focusingPage, let id = shownTabID { engineTab(for: id)?.focus() }
        // Every page: a Space switch closes the bar after the current Space changed.
        for spaceID in store.orderedSpaces.map(\.id) { pageView(for: spaceID)?.refreshNewTabRow() }
    }

    func isCommandBarOpen(mode: CommandBarMode) -> Bool { commandBar?.mode == mode }

    func focusPageUnlessTaken() {
        // Taken: a field or text view of this window, another window made key (a panel, a sheet), or a bar opened again.
        if commandBar != nil || !window.isKeyWindow && NSApp.keyWindow != nil { return }
        if let r = window.firstResponder, r !== window, r is NSText || r is NSTextView || r is NSControl { return }
        if let id = shownTabID { engineTab(for: id)?.focus() }
    }

    /// The parked bar shows what ⌘T will (CommandBarView.prepareForNextOpening): set a moment after whatever changes
    /// it (a tab shown or closed, a title or icon, a Space switch, the window's size, the bar closing), when nothing is
    /// moving, so its rows are drawn in an idle frame rather than in ⌘T's (§2.12).
    func scheduleSpareBarRefresh() {
        // The same moments can change which commands work (a tab shown or closed, its page, a Space): the command index
        // rebuilds at idle too (cbfirstkey).
        commandIndex.invalidate()
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

    /// Test builds can bring back "New ChatGPT Message" for one letter (`AIRC_CB_ASK_FIRST_KEY=1`): cbperf's A/B.
    static let askCommandOnFirstKey: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_CB_ASK_FIRST_KEY"] == "1"
        #else
        return false
        #endif
    }()

    func barCommandResults(for query: String, mode: CommandBarMode, inline: InlineCompletion.Match?,
                           inlineSite: CommonSites.Site?, suggestions: [String], history: [HistoryMatch]) -> [CommandResult] {
        composeCommandResults(for: query, mode: mode, inline: inline, inlineSite: inlineSite, suggestions: suggestions,
                              history: history, prepared: true)
    }

    func commandResults(for query: String, mode: CommandBarMode, inline: InlineCompletion.Match? = nil,
                        inlineSite: CommonSites.Site? = nil, suggestions: [String] = [],
                        history: [HistoryMatch] = []) -> [CommandResult] {
        composeCommandResults(for: query, mode: mode, inline: inline, inlineSite: inlineSite, suggestions: suggestions,
                              history: history, prepared: false)
    }

    /// `prepared`: the bar's keystrokes (barCommandResults), which may take the menu commands CommandIndex prepared.
    private func composeCommandResults(for query: String, mode: CommandBarMode, inline: InlineCompletion.Match?,
                                       inlineSite: CommonSites.Site?, suggestions: [String],
                                       history: [HistoryMatch], prepared: Bool) -> [CommandResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let profile = store.profile(ofSpace: currentSpaceID)

        // "/" (or Tab on an empty field): actions only.
        if q.hasPrefix("/") {
            let rest = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            let actions = prepared ? sessionCommands().list : commandActions(prepared: prepared)
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
        // keyframe: every open tab, pinned page and history row is shown by its display URL and host on every key, each
        // a URLComponents parse (~0.45 ms of a keystroke's frame): remembered per address (DisplayURLMemo).

        func addTab(_ t: LiveTab) {
            guard t.id != shownTabID else { return }
            let page = engineTab(for: t.id)
            let title = page?.title.isEmpty == false ? page!.title : t.displayTitle
            let id = "tab:" + t.id
            let recency = max(0, 3 - now.timeIntervalSince(t.lastActiveAt) / 3600)
            candidates.append(.init(id: id, kind: .openTab, title: title, subtitle: DisplayURLMemo.displayURL(t.url), boost: recency))
            actions[id] = CommandResult(title: title, subtitle: DisplayURLMemo.displayHost(t.url), badge: "Switch to Tab",
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
                                    subtitle: DisplayURLMemo.displayURL(saved)))
            actions[id] = CommandResult(title: item.displayTitle, subtitle: DisplayURLMemo.displayHost(saved),
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
        // The commands: ~400, nearly the same on every key. Their candidates are kept while the list's titles and words
        // stay the same (CommandIndex.CommandBlock, the bar's keys only), and their rows are made only for the few that
        // rank (cbrows). Each row is made from this key's list: its action and keycaps are always the current ones.
        // The unindexed path (cbperf's parity rows, `ParityCommandCatalog.bypassingIndex`) keeps nothing either.
        #if AIRC_TESTING
        let reuses = prepared && !ParityCommandCatalog.bypassing
        #else
        let reuses = prepared
        #endif
        let session = reuses && CommandBarView.keyframe2 ? Perf.time("cb.commands") { sessionCommands() } : nil
        let commandList = session?.list ?? Perf.time("cb.commands") { commandActions(prepared: prepared) }
        let block = Perf.time("cb.block") {
            session?.block ?? (reuses ? commandIndex.commandBlock(for: commandList) : CommandIndex.CommandBlock(commandList))
        }
        let stable = candidates.count..<(candidates.count + block.candidates.count)
        candidates += block.candidates
        func commandRow(_ id: String) -> CommandResult? {
            guard let i = block.lastIndex[id] else { return nil }
            let a = commandList[i]
            return CommandResult(title: a.title, subtitle: "", badge: "Run", icon: .symbol(a.symbol),
                                 matches: [], action: .run(a.run), shortcut: CommandResult.keys(of: a.hint))
        }

        if q.isEmpty {
            // ⌘T on its own: the most recent tabs of this profile first.
            let recent = CommandSearch.rank("", candidates.filter { $0.kind == .openTab }, limit: 6)
            if reuses { block.narrowing = nil }
            return recent.compactMap { actions[$0.candidate.id] }
        }

        // History (this profile only, searched off the main thread), ranked by match and frecency; pages that are open
        // or pinned show once, as the tab. A built-in site's completion is its home page: the same page from history
        // doesn't show again under it.
        let siteHome = inlineSite.map { DisplayURLMemo.displayURL($0.url) }
        do {
            for (i, r) in history.enumerated() where !urls.contains(r.entry.url) && r.entry.url != inline?.url
                && DisplayURLMemo.displayURL(r.entry.url) != siteHome {
                let id = "history:\(i)"
                let title = r.entry.title.isEmpty ? DisplayURLMemo.displayURL(r.entry.url) : r.entry.title
                // History scores already include the match; boost so a page you live on outranks a weak tab match.
                candidates.append(.init(id: id, kind: .history, title: title, subtitle: DisplayURLMemo.displayURL(r.entry.url),
                                        boost: min(12, 4 * log2(1 + r.entry.frecency(now: now)))))
                actions[id] = CommandResult(title: title, subtitle: DisplayURLMemo.displayHost(r.entry.url), badge: "Open",
                                            icon: .favicon(image: nil, url: nil, page: r.entry.url), matches: [],
                                            action: .open(URL(string: r.entry.url)!), historyURL: r.entry.url)
            }
        }

        // Well-known sites (CommonSites) you have never been to, below every result of yours that matches as well, one
        // or two of them (more for a site's exact name); not the one already completed inline, nor the address typed.
        var personal = Perf.time("cb.rank") { () -> [CommandSearch.Result] in
            // Only the bar's own keys narrow: what another caller ranks must not change what the next key may skip.
            guard reuses else { return CommandSearch.rank(q, candidates, limit: 7) }
            var n = block.narrowing
            defer { block.narrowing = n }
            return CommandSearch.rank(q, candidates, limit: 7, stable: stable, narrowing: &n, prepared: session?.prepared)
        }
        // cbfixes: "New ChatGPT Message" (Ask Claude…) from two letters on ("gp", "ne", "ask"), never for the first
        // one: with Automatic on for ChatGPT users, "g" showed it and its row cost the first key ~1 ms (askai's cbperf).
        if q.count < 2, !Self.askCommandOnFirstKey, let askID = askAICommandID {
            personal.removeAll { $0.candidate.id == askID }
        }
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
                guard var res = actions[r.candidate.id] ?? (r.candidate.kind == .action ? commandRow(r.candidate.id) : nil) else { return nil }
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

    /// The bar's commands for this opening (keyframe2): made by its first key, then kept while nothing they are made from
    /// changed. Every key used to make all ~400 again (the menus' prepared list, the window's and the context menus'
    /// actions: ~0.6 ms of its frame) only to find them the same (CommandBlock.matches). What can change them bumps the
    /// command index's generation (a store change, a shown tab, the key window, a menu); the rest of what titles them
    /// is in `CommandListKey`. Dropped when the bar opens and closes.
    struct CommandListKey: Equatable {
        var owner: ObjectIdentifier
        var generation: Int
        var space: String
        var shownTab: String?
        var shownSplit: String?
        var currentTab: String?
        var isToday: Bool?
        var drifted: Bool
        var sidebarHidden: Bool
        var toolbar: Bool
        var askPage: Bool
        var spaces: Int
    }

    struct SessionCommands {
        var key: CommandListKey
        var list: [CommandAction]
        var block: CommandIndex.CommandBlock
        /// Made after the first key's commit (that key ranks without it: same results), not in its frame.
        var prepared: CommandSearch.PreparedRun?
    }

    static var commandMemo: SessionCommands?

    private var commandListKey: CommandListKey {
        let t = currentTab
        return CommandListKey(owner: ObjectIdentifier(self), generation: commandIndex.generation, space: currentSpaceID,
                              shownTab: shownTabID, shownSplit: shownSplitID, currentTab: t?.id, isToday: t?.isToday,
                              drifted: t.map { !$0.isToday && store.isDrifted($0.id) } ?? false,
                              sidebarHidden: sidebarHidden, toolbar: pageToolbar != nil,
                              askPage: app?.settings.values.askPage == true, spaces: store.orderedSpaces.count)
    }

    /// This opening's commands, their candidate block and its prepared texts (the bar's own keys only).
    func sessionCommands() -> SessionCommands {
        let key = commandListKey
        if let m = Self.commandMemo, m.key == key { return m }
        let list = commandActions(prepared: true)
        let block = commandIndex.commandBlock(for: list)
        let prepared = Self.commandMemo.flatMap { $0.block === block ? $0.prepared : nil }
        let made = SessionCommands(key: key, list: list, block: block, prepared: prepared)
        Self.commandMemo = made
        if prepared == nil {
            // A timer, not `async`: the main queue drains before this frame's commit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) {
                guard let m = Self.commandMemo, m.block === block, m.prepared == nil else { return }
                let run = Perf.time("cb.prepare") { CommandSearch.PreparedRun(block.candidates) }
                if Self.commandMemo?.block === block { Self.commandMemo?.prepared = run }
            }
        }
        return made
    }

    /// `URLRules.displayURL` and `displayHost`, remembered per address (keyframe). They depend on the address alone; the
    /// table is dropped when it grows past 4,000 addresses.
    enum DisplayURLMemo {
        private static var urls: [String: String] = [:]
        private static var hosts: [String: String] = [:]

        static func displayURL(_ url: String) -> String {
            guard CommandBarView.keyframe else { return URLRules.displayURL(url) }
            if let hit = urls[url] { return hit }
            if urls.count > 4000 { urls = [:] }
            let v = URLRules.displayURL(url)
            urls[url] = v
            return v
        }

        static func displayHost(_ url: String) -> String {
            guard CommandBarView.keyframe else { return URLRules.displayHost(url) }
            if let hit = hosts[url] { return hit }
            if hosts.count > 4000 { hosts = [:] }
            let v = URLRules.displayHost(url)
            hosts[url] = v
            return v
        }
    }

    struct CommandAction {
        var title: String
        var symbol: String
        var hint: String
        var keywords: [String]
        var run: () -> Void
    }

    func commandActions(prepared: Bool = false) -> [CommandAction] {
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
        a.append(.init(title: "Send Feedback", symbol: "bubble.left.and.text.bubble.right", hint: "",
                       // feedback2: "feed", "bug", "report" put it first (an exact keyword outranks the search row).
                       keywords: ["feedback", "contact the team", "bug", "bug report", "report", "report a problem", "issue",
                                  "suggestion", "help"]) { [weak self] in
            guard let self, let app = self.app else { return }
            FeedbackSheet.show(from: self.window, app: app)
        })
        a += askAICommandActions()   // P07b: Arc's "New ChatGPT Message" (ChatGPTCommand.swift)
        a += agentsCommandActions()   // Connect Claude and other AI apps… (Agent/AgentsConnect.swift)
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
            // Ask on Page (AI/AskPageCard.swift) on a page: while it's off or can't run, choosing it says why and opens
            // Settings › AI from its card (owner, 0.1.26: "ask page" found nothing and beeped).
            if shownTabID.flatMap({ engineTab(for: $0) }) != nil {
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
        a += Perf.time("cb.actions.context") { contextCommandActions() }   // the menus' actions (Browser/WindowActions.swift)
        a += Perf.time("cb.actions.parity") { menuParityCommandActions() }   // S09: Mute All Tabs, Rename Current Tab, Pin to “Folder” (Browser/MenuMoveAndBulk.swift)
        a += Perf.time("cb.actions.menu") { menuCommandActions(excluding: Set(a.map(\.title)), prepared: prepared) }   // the menu bar's (App/ParityCommandCatalog.swift)
        return a
    }
}
