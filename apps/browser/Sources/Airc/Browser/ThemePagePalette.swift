// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// Arc's page palette (P07, P05; AircKit ThemeCSS, AircDesign `ResolvedTheme.pagePalette`): every web page gets the
/// theme of its own Space as Arc's CSS custom properties (`--arc-palette-background`, …), so pages and Boosts written
/// for Arc look the same here.
///   - Whose palette: the page's tab's Space (a Favorite's: the Space its window shows), in the appearance the window
///     draws it with (the theme's own, or the system's for an automatic theme). A page with no Space (a private
///     window, Little Arc) gets none.
///   - Keys: each Space's palette has a short key; the "theme" part of the page script carries every Space's palette by
///     key. Each engine tab is told its key (`AircTab.pageColor`, the engine's per-tab page data, set as the page is
///     adopted and whenever its Space changes), so a document whose engine hands the key to the page script at document
///     start (`install(post, data)`) has its palette before it paints.
///   - A key names one palette for good: a Space whose palette changes gets a new key. The page script reaches the
///     engine a moment after a change (pushes are coalesced, PageScripts.set), while a tab's key reaches it at once; a
///     document starting in between has a script without the new key, so it starts without a palette and gets it from
///     the app's first message, instead of painting the Space's old colours under its key (ship run 05:48, themeparity on
///     Chromium with the engine's per-tab data). A page adopted then pushes the script first.
///   - Live: each top-frame document says `ready` with its token and the key it shows; it gets `palette` when that isn't
///     its tab's (no key at document start, the Space's theme changed, the system appearance changed, the tab moved
///     to another Space). Messages go through `callDocument` (the same frame and origin) and carry the token.
final class ThemePagePalette {
    static private(set) var shared: ThemePagePalette?

    private weak var app: AppDelegate?
    private let scripts: PageScripts
    /// Space → key, and key → that Space's palette now.
    private var keys: [String: String] = [:]
    private var nextKey = 0
    private(set) var palettes: [String: ThemeCSS.Palette] = [:]
    /// Each Space's palette with the theme and appearance it was made from: most store changes touch no theme.
    private var made: [String: (theme: AircKit.SpaceTheme, dark: Bool, palette: ThemeCSS.Palette)] = [:]
    private var documents: [ObjectIdentifier: Document] = [:]
    private var storeObserver: Int?
    private var appearance: NSKeyValueObservation?
    private var systemDark: Bool
    /// When the page script last got new palettes; a page adopted within the push delay pushes it first.
    private var changedAt: CFTimeInterval = 0

    struct Document {
        weak var tab: EngineTab?
        var frame: String
        var origin: String
        var token: String
        /// The key the document shows ("" for none), and that palette's CSS as it was sent (a Space's key stays when its
        /// theme or the appearance changes; its CSS doesn't).
        var shown: String
        var shownCSS: String?
        /// The engine handed the page script its tab's key at document start.
        var engineData: Bool
    }

    #if AIRC_TESTING
    /// Scripted checks (ThemeParityCheck): what each document said and was sent.
    private(set) var log: [(tab: Int, event: String)] = []
    func document(of tab: EngineTab) -> Document? { documents[ObjectIdentifier(tab)] }
    func key(forSpace id: String) -> String? { keys[id] }
    #endif

    /// After BoostCenter.start (which made the engine's page script the app's), before the first page opens.
    static func start(app: AppDelegate) {
        guard shared == nil, let scripts = PageScripts.shared else { return }
        let p = ThemePagePalette(app: app, scripts: scripts)
        shared = p
        p.rebuild(push: true)
    }

    private init(app: AppDelegate, scripts: PageScripts) {
        self.app = app
        self.scripts = scripts
        systemDark = Self.isDark(NSApp.effectiveAppearance)
        storeObserver = app.store.observe { [weak self] change in
            guard let self, !change.contentOnly else { return }
            self.rebuild(push: false)
        }
        appearance = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let dark = Self.isDark(app.effectiveAppearance)
                guard dark != self.systemDark else { return }
                self.systemDark = dark
                self.rebuild(push: true)
            }
        }
    }

    static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: Palettes

    /// The page palette of one theme, as CSS values.
    static func palette(_ theme: AircKit.SpaceTheme, systemDark: Bool) -> ThemeCSS.Palette {
        let p = theme.design.resolved(systemIsDark: systemDark).pagePalette
        func css(_ c: AircColor) -> String { ThemeCSS.color(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha) }
        return ThemeCSS.Palette(palette: ResolvedTheme.PagePalette.names.map { ($0, css(p.colors[$0] ?? .clear)) },
                                simple: css(p.simple), gradient: p.gradient.map(css), overlay: p.overlay.map(css))
    }

    /// Every Space's palette now; pushes the page script when one changed (or `push`: at start), then brings open pages
    /// and engine tabs up to date.
    private func rebuild(push: Bool) {
        guard let store = app?.store else { return }
        var next: [String: ThemeCSS.Palette] = [:]
        for space in store.state.spaces.values {
            let palette: ThemeCSS.Palette
            if let m = made[space.id], m.theme == space.theme, m.dark == systemDark {
                palette = m.palette
            } else {
                palette = Self.palette(space.theme, systemDark: systemDark)
                made[space.id] = (space.theme, systemDark, palette)
            }
            // The Space keeps its key while its palette stays; another palette gets another key.
            if let k = keys[space.id], palettes[k] == palette {
                next[k] = palette
            } else {
                let k = ThemeCSS.key(nextKey)
                nextKey += 1
                keys[space.id] = k
                next[k] = palette
            }
        }
        for (id, _) in keys where store.state.spaces[id] == nil { keys[id] = nil; made[id] = nil }
        let changed = next != palettes
        palettes = next
        if changed || push {
            if push || !Self.defersScript { setScript() } else { scheduleScript() }
            changedAt = CACurrentMediaTime()
        }
        refreshPages()
    }

    /// The page script's palettes, as JSON for every Space, are made a moment after a store change, not inside it: in
    /// Create Space's frame they took 0.8–2.4 ms (P02b), and the engine only gets the script with PageScripts' coalesced
    /// push 0.25 s later anyway. Keys, engine tabs and open documents still change at once (`refreshPages`); a page
    /// adopted before the script is set sets it first (`adopted`).
    private var scriptPending = false

    private func setScript() {
        scriptPending = false
        scripts.set(ThemeCSS.part, source: ThemeCSS.source(palettes: palettes)) { [weak self] tab, m in self?.received(tab, m) }
    }

    private func scheduleScript() {
        guard !scriptPending else { return }
        scriptPending = true
        // A timer, not `async`: the main queue can drain before the frame's Core Animation commit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self, self.scriptPending else { return }
            self.setScript()
        }
    }

    /// Test builds can make the script inside the change, as before (`AIRC_PAGE_PALETTE_BASELINE=1`), to compare both in
    /// one binary.
    private static let defersScript: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_PAGE_PALETTE_BASELINE"] != "1"
        #else
        return true
        #endif
    }()

    /// The key a page's tab should show: its Space's, or "" (no Space: a private window, Little Arc).
    func expectedKey(for tab: EngineTab) -> String {
        guard let app, let c = app.controller(owning: tab), let tabID = c.tabID(for: tab) else { return "" }
        let spaceID = c.store.tab(tabID)?.spaceID ?? c.currentSpaceID
        return keys[spaceID] ?? ""
    }

    /// Every open window's pages: their engine tabs carry their key, their documents show it.
    private func refreshPages() {
        guard let app else { return }
        for c in app.controllers {
            for tabID in c.store.state.tabs.keys {
                guard let page = c.engineTab(for: tabID) else { continue }
                setEngineKey(page, expectedKey(for: page))
            }
        }
        for (key, doc) in documents {
            guard let tab = doc.tab, !tab.isClosed else { documents[key] = nil; continue }
            let want = expectedKey(for: tab)
            if doc.shown != want || doc.shownCSS != (palettes[want]?.css ?? "") { send(want, to: key) }
        }
    }

    /// A window took a page as one of its tabs (WindowController.adopt): its engine tab gets its key before its next
    /// document commits.
    func adopted(_ page: EngineTab) {
        // Its first document should find its key in the page script: push a change still waiting for its delay.
        if changedAt > 0, CACurrentMediaTime() - changedAt < 0.5 {
            changedAt = 0
            if scriptPending { setScript() }
            scripts.pushNow()
        }
        setEngineKey(page, expectedKey(for: page))
        let want = expectedKey(for: page)
        if let doc = documents[ObjectIdentifier(page)], doc.shown != want || doc.shownCSS != (palettes[want]?.css ?? "") {
            send(want, to: ObjectIdentifier(page))
        }
    }

    private func setEngineKey(_ page: EngineTab, _ key: String) {
        #if canImport(AircCore)
        if let core = (page as? ChromiumTab)?.core, (core.pageColor ?? "") != key { core.pageColor = key.isEmpty ? nil : key }
        #endif
    }

    // MARK: Documents

    @discardableResult
    private func send(_ key: String, to id: ObjectIdentifier) -> Bool {
        guard var doc = documents[id], let tab = doc.tab, !tab.isClosed else { documents[id] = nil; return false }
        let css = palettes[key]?.css ?? ""
        let sent = scripts.callDocument(tab, frame: doc.frame, origin: doc.origin, part: ThemeCSS.part, kind: "palette",
                                        json: ThemeCSS.message(token: doc.token, key: css.isEmpty ? "" : key, css: css))
        if sent { doc.shown = css.isEmpty ? "" : key; doc.shownCSS = css; documents[id] = doc } else { documents[id] = nil }
        #if AIRC_TESTING
        log.append((tab.tabID, "sent \(css.isEmpty ? "-" : key) delivered \(sent)"))
        #endif
        return sent
    }

    private func received(_ tab: EngineTab, _ m: EnginePageMessage) {
        guard m.isMainFrame, m.kind == "ready", !tab.isClosed else { return }
        let id = ObjectIdentifier(tab)
        documents = documents.filter { $0.value.tab != nil && $0.value.tab?.isClosed == false }
        let body = (try? JSONSerialization.jsonObject(with: Data(m.json.utf8))) as? [String: Any] ?? [:]
        guard let token = body["t"] as? String, !token.isEmpty else { documents[id] = nil; return }
        let shown = body["k"] as? String ?? ""
        // A key from document start names one palette for good: palettes[key] if it's still a Space's, else none (old).
        documents[id] = Document(tab: tab, frame: m.frame, origin: m.origin, token: token, shown: shown,
                                 shownCSS: shown.isEmpty ? "" : palettes[shown]?.css, engineData: body["d"] as? Bool == true)
        #if AIRC_TESTING
        log.append((tab.tabID, "ready shows \(shown.isEmpty ? "-" : shown) engine data \(body["d"] as? Bool == true)"))
        #endif
        let want = expectedKey(for: tab)
        setEngineKey(tab, want)
        if shown != want || documents[id]?.shownCSS != (palettes[want]?.css ?? "") { send(want, to: id) }
    }
}
