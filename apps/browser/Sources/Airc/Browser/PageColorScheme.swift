// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// The colour scheme web pages prefer (`prefers-color-scheme`, `color-scheme: light dark`), as Arc decides it: from the
/// mode the page's Space draws in. A dark Space's pages are dark, a light one's light, and an automatic theme's follow
/// the system (its very light or very dark colours keep their own mode, as the sidebar does). So a page always matches
/// the sidebar beside it, and when macOS switches between light and dark (Appearance: Auto at sunset and sunrise), every
/// open page follows at once, as in Safari and Chrome, instead of keeping the scheme it loaded with.
///   - Whose mode: a window tab's Space (a Favorite's: the Space its window shows); a Peek's, the window's Space it
///     opens over; Little Airc's, its target Space; a private window follows the system.
///   - Live: the system appearance (NSApp's), a Space's theme, a tab moved to another Space, Little Airc's target
///     Space. Each engine tab is told its scheme as it's adopted, before its first document commits where it can be.
///   - Engines: WebKit pages follow their web view's appearance; Chromium pages take it from the engine tab's
///     `preferredColorScheme` (airc_color_scheme.h), which reaches the open page's media queries and matchMedia
///     listeners at once.
final class PageColorScheme {
    static private(set) var shared: PageColorScheme?

    enum Scheme: Int, Equatable { case engine = 0, light = 1, dark = 2 }

    private weak var app: AppDelegate?
    private var storeObserver: Int?
    private var appearance: NSKeyValueObservation?
    private(set) var systemDark: Bool
    private var refreshPending = false
    /// Each Space's mode with the theme and system appearance it was worked out from (resolving a theme isn't free).
    private var made: [String: (theme: AircKit.SpaceTheme, systemDark: Bool, dark: Bool)] = [:]

    #if AIRC_TESTING
    /// Scripted checks (AutoDarkCheck): how many pages each refresh changed, and the system appearance it saw.
    private(set) var log: [String] = []
    #endif

    static func start(app: AppDelegate) {
        guard shared == nil else { return }
        #if AIRC_TESTING
        // AutoDarkCheck's before arm: pages keep the engines' own choice, as before this existed.
        if ProcessInfo.processInfo.environment["AIRC_PAGE_SCHEME_OFF"] == "1" { return }
        #endif
        let s = PageColorScheme(app: app)
        shared = s
        s.refresh(reason: "start")
    }

    private init(app: AppDelegate) {
        self.app = app
        systemDark = Self.isDark(NSApp.effectiveAppearance)
        // After the change, not inside it (a store change's frame is busy; the page follows on the next turn).
        storeObserver = app.store.observe { [weak self] change in
            guard let self, !change.contentOnly, !self.refreshPending else { return }
            self.refreshPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshPending else { return }
                self.refresh(reason: "store")
            }
        }
        // NSApp's effective appearance changes with the system's (AppleInterfaceThemeChangedNotification) and with
        // NSApp.appearance; KVO sees both.
        appearance = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                #if AIRC_TESTING
                if self?.ignoresAppearanceKVO == true { return }
                #endif
                self?.systemAppearanceChanged()
            }
        }
        // The system's own signal for the Auto switch; NSApp's appearance may update a moment after it posts.
        themeChanged = DistributedNotificationCenter.default().addObserver(
            forName: Self.themeChangedNotification, object: nil, queue: .main) { [weak self] _ in self?.themeNotification() }
    }

    deinit { if let themeChanged { DistributedNotificationCenter.default().removeObserver(themeChanged) } }

    static let themeChangedNotification = Notification.Name("AppleInterfaceThemeChangedNotification")
    private var themeChanged: NSObjectProtocol?

    static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func themeNotification() {
        systemAppearanceChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.systemAppearanceChanged() }
    }

    #if AIRC_TESTING
    /// AutoDarkCheck: mutes the NSApp appearance KVO, so the theme notification alone has to bring pages along, and
    /// delivers that notification to this observer only (posting the real one would reach every app on the Mac).
    var ignoresAppearanceKVO = false
    func simulateThemeNotification() { themeNotification() }
    #endif

    /// Also called when the system posts its theme change, in case NSApp's appearance is read before KVO fires.
    func systemAppearanceChanged() {
        let dark = Self.isDark(NSApp.effectiveAppearance)
        guard dark != systemDark else { return }
        systemDark = dark
        refresh(reason: dark ? "system dark" : "system light")
    }

    // MARK: Deciding

    /// The mode a Space draws in now: its theme's own, or the system's for an automatic theme.
    func isDark(space: Space?) -> Bool {
        guard let space else { return systemDark }
        if let m = made[space.id], m.theme == space.theme, m.systemDark == systemDark { return m.dark }
        let dark = Palette(theme: space.theme, systemDark: systemDark).isDark
        made[space.id] = (space.theme, systemDark, dark)
        return dark
    }

    func scheme(space: Space?) -> Scheme { isDark(space: space) ? .dark : .light }

    /// A window tab's scheme: its own Space's (a Favorite has none; it shows in the window's Space).
    func scheme(for page: EngineTab, in c: WindowController) -> Scheme {
        if let tabID = c.tabID(for: page) {
            let spaceID = c.store.tab(tabID)?.spaceID ?? c.currentSpaceID
            return scheme(space: c.store.space(spaceID) ?? c.store.space(c.currentSpaceID))
        }
        // A Peek, or a page on its way in: the Space the window shows.
        return scheme(space: c.store.space(c.currentSpaceID))
    }

    /// Any engine tab's scheme, wherever it is (nil: nobody owns it, it keeps what it has).
    func scheme(for page: EngineTab) -> Scheme? {
        guard let app else { return nil }
        if let c = app.controller(owning: page) { return scheme(for: page, in: c) }
        for c in app.controllers where c.peek?.page === page { return scheme(for: page, in: c) }
        for l in app.littleArcs where l.page === page { return scheme(space: app.store.space(l.spaceID) ?? app.store.selectedSpace) }
        for w in PrivateBrowsing.shared.windows where w.pages.contains(where: { $0.tab === page }) {
            return systemDark ? .dark : .light
        }
        return nil
    }

    // MARK: Applying

    /// Brings every open page up to date.
    func refresh(reason: String) {
        refreshPending = false
        guard let app else { return }
        var changed = 0
        func set(_ page: EngineTab, _ s: Scheme) { if apply(s, to: page) { changed += 1 } }
        for c in app.controllers {
            for tabID in c.store.state.tabs.keys {
                guard let page = c.engineTab(for: tabID) else { continue }
                set(page, scheme(for: page, in: c))
            }
            if let p = c.peek?.page, !p.isClosed { set(p, scheme(for: p, in: c)) }
        }
        for l in app.littleArcs {
            if let p = l.page, !p.isClosed { set(p, scheme(space: app.store.space(l.spaceID) ?? app.store.selectedSpace)) }
        }
        for w in PrivateBrowsing.shared.windows {
            for p in w.pages where !p.tab.isClosed { set(p.tab, systemDark ? .dark : .light) }
        }
        #if AIRC_TESTING
        if changed > 0 || reason != "store" { log.append("\(reason): \(changed) changed, system \(systemDark ? "dark" : "light")") }
        #endif
    }

    /// A page was just made or adopted (a window tab, Peek, Little Airc): its scheme before its first document commits.
    func adopted(_ page: EngineTab) {
        if let s = scheme(for: page) { apply(s, to: page) }
    }

    /// A page's own scheme (a Peek's or Little Airc's before it's registered anywhere).
    func adopted(_ page: EngineTab, space: Space?) { apply(scheme(space: space), to: page) }

    @discardableResult
    private func apply(_ s: Scheme, to page: EngineTab) -> Bool {
        guard !page.isClosed, let tab = page as? EngineColorSchemeTab, tab.pageColorScheme != s else { return false }
        tab.pageColorScheme = s
        return true
    }
}

/// An engine tab whose page's preferred colour scheme the app sets (both engines' tabs).
protocol EngineColorSchemeTab: AnyObject {
    var pageColorScheme: PageColorScheme.Scheme { get set }
}
