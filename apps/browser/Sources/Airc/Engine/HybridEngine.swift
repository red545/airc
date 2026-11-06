// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

// Protected media (docs/user/protected-media.md): Spotify, Netflix, Disney+ and the other big services play in a WebKit
// page inside the Chromium build, with Apple's FairPlay; everything else stays Chromium. Their licence servers refuse
// Chromium's Widevine without Google's Verified Media Path certification (engine/DRM.md). The design follows Cra's
// (github.com/VictorKildahl/cra, docs/protected-media.md, MIT).
//
// The Chromium adapter is the composite: ChromiumEngine owns a WebKitEngine, each ChromiumProfile its WebKitProfile
// (one persistent store per profile, named from the data folder plus the profile), and each ChromiumWindow a
// WebKitWindow around the same NSWindow and page host. The EngineWindow calls (openTab, activateTab, presentPanes…)
// choose per page below, so WindowController and the tab model see one engine. A page that changes engine is a new
// EngineTab; the window delegate's `replace` puts it in the old one's place (EngineWindowDelegate). A separate
// `BrowserEngine` class would have turned off every Chromium feature the app reaches with `engine as? ChromiumEngine`.

/// The rules in force (AircKit's ProtectedMediaSites) with the person's choices and the setting.
final class ProtectedMedia {
    static let shared = ProtectedMedia()

    /// The person's choices: sites sent to WebKit or back, and the services whose toast was closed.
    private(set) var choices: ProtectedMediaChoices
    private var base: ProtectedMediaSites
    private let file: URL

    private init() {
        file = AppPaths.dataDirectory.appendingPathComponent("protected-media.json")
        choices = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ProtectedMediaChoices.self, from: $0) }
            ?? ProtectedMediaChoices()
        base = ProtectedMediaSites()
        rebuild()
    }

    /// Settings → Privacy → "Play DRM sites with Safari's engine" (on by default). Off: every new page is Chromium's.
    var isEnabled: Bool {
        #if AIRC_TESTING
        if let v = ProcessInfo.processInfo.environment["AIRC_WEBKIT_DRM"] { return v != "0" }
        #endif
        return (NSApp.delegate as? AppDelegate)?.settings?.values.webKitProtectedMedia ?? true
    }

    var sites: ProtectedMediaSites {
        var s = base
        s.isEnabled = isEnabled
        return s
    }

    private func rebuild() {
        var extra = choices.added
        #if AIRC_TESTING
        // A test's loopback host plays the part of a service (the drmwebkit scenario lists "localhost").
        extra += (ProcessInfo.processInfo.environment["AIRC_WEBKIT_HOSTS"] ?? "").split(separator: ",").map(String.init) + testHosts
        #endif
        base = ProtectedMediaSites(extraHosts: extra, removedHosts: choices.removed)
    }

    #if AIRC_TESTING
    /// Hosts a scripted check lists as services (`--script drmwebkit`: "localhost").
    var testHosts: [String] = [] { didSet { rebuild() } }
    #endif

    func engine(for url: URL?) -> PageEngine {
        url.map { sites.engine(for: $0.absoluteString) } ?? .chromium
    }

    /// "Spotify" for a page on a listed service's site.
    func service(of url: URL?) -> String? { url.flatMap { sites.serviceName(for: $0.absoluteString) } }

    /// The "Safari's engine" switch: `url`'s site plays in `engine` from now on.
    func choose(_ engine: PageEngine, for url: URL) {
        choices = choices.choosing(engine, for: url.absoluteString)
        rebuild()
        save()
    }

    func wasTold(_ service: String) -> Bool { choices.told.contains(service) }

    /// The toast's ✕ was pressed: it doesn't come back for this service.
    func told(_ service: String) {
        guard !wasTold(service) else { return }
        choices = choices.telling(service)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(choices) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Whether `tab` is a WebKit page of the Chromium build (its extensions, DevTools and sleep work differently).
    static func isWebKitPage(_ tab: EngineTab?) -> Bool {
        #if canImport(AircCore)
        return tab is WebKitTab && (NSApp.delegate as? AppDelegate)?.engine is ChromiumEngine
        #else
        return false
        #endif
    }
}

#if canImport(AircCore)
import AircCore

/// A ChromiumProfile's WebKit side: its WebKitProfile (made with its first WebKit page) and the app's observers that
/// need both engines' rows (downloads, the media tray).
final class HybridProfileState {
    var webKit: WebKitProfile?
    var downloadsHandler: ((EngineDownload) -> Void)?
    var mediaHandler: (([EngineTab]) -> Void)?
    var chromiumMediaTabs: [EngineTab] = []
    var webKitMediaTabs: [EngineTab] = []

    func emitMediaTabs() { mediaHandler?(chromiumMediaTabs + webKitMediaTabs) }
}

extension ChromiumEngine {
    /// The profile's WebKit side, made the first time a page needs it.
    func webKitProfile(for profile: EngineProfile) -> WebKitProfile? {
        guard let p = profile as? ChromiumProfile else { return nil }
        if let w = p.hybrid.webKit { return w }
        var made: WebKitProfile?
        webKit.loadProfile(directory: p.directory) { made = $0 as? WebKitProfile }
        guard let w = made else { return nil }
        p.hybrid.webKit = w
        // Observers the app installed before this profile's first WebKit page.
        if let h = p.hybrid.downloadsHandler { webKit.observeDownloadItems(in: w, h) }
        if p.hybrid.mediaHandler != nil {
            webKit.observeMediaTabs(in: w) { [weak state = p.hybrid] tabs in
                state?.webKitMediaTabs = tabs
                state?.emitMediaTabs()
            }
        }
        return w
    }

    /// Deletes a profile's WebKit cookies and storage (the profile was deleted).
    func deleteWebKitData(directory: String, completion: @escaping (Bool) -> Void) {
        profiles.values.first { $0.directory == directory }?.hybrid.webKit = nil
        webKit.deleteStore(directory: directory, completion: completion)
    }

    /// A profile's WebKit side if it has one (nil: none of its pages has been WebKit's yet).
    func loadedWebKitProfile(for profile: EngineProfile) -> WebKitProfile? { (profile as? ChromiumProfile)?.hybrid.webKit }
}

/// A ChromiumWindow's WebKit pages: a WebKitWindow around the same NSWindow and page host, whose window callbacks reach
/// the app as the Chromium window's.
final class HybridWebKitSide: NSObject, EngineWindowDelegate {
    private weak var owner: ChromiumWindow?
    private(set) var made: WebKitWindow?
    private var closing: NSObjectProtocol?

    init(window: ChromiumWindow) { owner = window }

    deinit { closing.map(NotificationCenter.default.removeObserver) }

    var window: WebKitWindow {
        if let made { return made }
        let w = WebKitWindow(window: owner!.window, hostView: owner!.hostView)
        w.delegate = self
        w.linkPolicy = { [weak self] tab, url, newTab, background in
            self?.owner?.webKitLink(tab, url: url, newTab: newTab, background: background) ?? false
        }
        // The window closing (Little Arc, the call window) closes its WebKit pages too; Chromium closes its own.
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner!.window,
                                                         queue: .main) { [weak w] _ in w?.tabs.forEach { $0.close() } }
        made = w
        return w
    }

    /// The WebKit page on screen (alone or in a split) goes; one playing video goes to picture in picture.
    func hide(except keep: WebKitTab? = nil) {
        guard let made else { return }
        let leaving = made.visibleTabs.filter { $0 !== keep }
        made.deactivateAll()
        leaving.forEach { owner?.autoPictureInPicture($0) }
    }

    // MARK: EngineWindowDelegate (the WebKitWindow's), on to the app as the Chromium window's

    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) {
        guard let owner else { return tab.close() }
        owner.delegate?.engineWindow(owner, didInsertTab: tab, opener: opener, disposition: disposition)
    }

    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {
        guard let owner else { return }
        owner.delegate?.engineWindow(owner, tabRequestedClose: tab)
    }

    func engineWindow(_ window: EngineWindow, tabCancelledClose tab: EngineTab) {
        guard let owner else { return }
        owner.delegate?.engineWindow(owner, tabCancelledClose: tab)
    }

    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {
        guard let owner else { return }
        owner.delegate?.engineWindow(owner, tab: tab, didChangeFullscreen: fullscreen)
    }
}

// MARK: - The window's EngineWindow calls, per page

extension ChromiumWindow {
    private var media: ProtectedMedia { .shared }

    func openTab(url: URL?, profile: EngineProfile, foreground: Bool) -> EngineTab {
        if let url, media.engine(for: url) == .webKit, let wk = engine.webKitProfile(for: profile) {
            let tab = webKit.window.openTab(url: url, profile: wk, hostProfile: profile, foreground: false)
            if foreground { activateTab(tab) }
            return tab
        }
        let tab = openChromiumTab(url: url, profile: profile, foreground: foreground)
        if url != nil { (tab as? ChromiumTab)?.getNavigationStarted = Date() }
        return tab
    }

    func activateTab(_ tab: EngineTab) {
        guard let t = tab as? WebKitTab else {
            webKit.hide()
            return activateChromiumTab(tab)
        }
        guard t.window === webKit.made, !t.isClosed else { return }
        hideChromiumPages()
        webKit.hide(except: t)
        webKit.window.activateTab(t)
    }

    func deactivateAll() {
        webKit.hide()
        deactivateChromium()
    }

    /// SV-1 with one engine per pane: each engine shows its own panes and hides its other pages.
    func presentPanes(_ panes: [(tab: EngineTab, host: NSView)], focused: EngineTab) throws {
        guard (1...4).contains(panes.count),
              Set(panes.map { ObjectIdentifier($0.tab) }).count == panes.count,
              Set(panes.map { ObjectIdentifier($0.host) }).count == panes.count,
              panes.allSatisfy({ $0.host.window === window && !$0.tab.isClosed }),
              panes.contains(where: { $0.tab === focused }) else {
            throw EngineHostingError.rejected("invalidPanes")
        }
        let webPanes = panes.compactMap { p in (p.tab as? WebKitTab).map { (tab: $0, host: p.host) } }
        guard webPanes.allSatisfy({ $0.tab.window === webKit.made }) else { throw EngineHostingError.rejected("invalidPanes") }
        try presentChromiumPanes(panes.filter { !($0.tab is WebKitTab) }, focused: focused)
        let before = webKit.made?.visibleTabs ?? []
        if webPanes.isEmpty { webKit.hide() } else { webKit.window.attachPanes(webPanes) }
        for t in before where !webPanes.contains(where: { $0.tab === t }) { autoPictureInPicture(t) }
        focusPane(focused)
    }

    func focusPane(_ tab: EngineTab) {
        if let t = tab as? WebKitTab { webKit.made?.focusPane(t) } else { focusChromiumPane(tab) }
    }

    func moveTab(_ tab: EngineTab, profile: EngineProfile, to host: NSView) throws {
        guard let t = tab as? WebKitTab else { return try moveChromiumTab(tab, profile: profile, to: host) }
        try webKit.window.moveTab(t, profile: profile, to: host)
        if host === hostView { hideChromiumPages() }
    }

    func openPeek(url: URL, opener: EngineTab, in host: NSView) throws -> EngineTab {
        // A listed site, or a WebKit page's link: WebKit (its sign-in has to come back to the same cookies).
        let wk = opener is WebKitTab || media.engine(for: url) == .webKit
        guard wk, let profile = engine.webKitProfile(for: opener.profile), host.window === window else {
            return try openChromiumPeek(url: url, opener: opener, in: host)
        }
        return webKit.window.openPeek(url: url, profile: profile, hostProfile: opener.profile, in: host)
    }

    func tabs(for profile: EngineProfile) -> [EngineTab] {
        chromiumTabs(for: profile) + (webKit.made?.tabs(for: profile) ?? [])
    }

    /// The URL bar picks the engine again; a sign-in host stays where it is.
    func load(_ url: URL, in tab: EngineTab) {
        let current: PageEngine = tab is WebKitTab ? .webKit : .chromium
        let wanted = media.sites.engine(forAddressBar: url.absoluteString, current: current)
        guard wanted == current || !reopen(tab, url: url, in: wanted) else { return }
        (tab as? ChromiumTab)?.getNavigationStarted = Date()
        tab.load(url)
    }

    // MARK: Handoffs

    /// `old` opens again at `url` in `wanted`, in its place (the delegate's `replace`). False: nothing changed.
    @discardableResult
    func reopen(_ old: EngineTab, url: URL, in wanted: PageEngine) -> Bool {
        guard !old.isClosed, let delegate, delegate.engineWindowCanReplaceTabs(self) else { return false }
        let new: EngineTab
        switch wanted {
        case .webKit:
            guard let wk = engine.webKitProfile(for: old.profile) else { return false }
            new = webKit.window.openTab(url: url, profile: wk, hostProfile: old.profile, foreground: false)
        case .chromium:
            new = openChromiumTab(url: url, profile: old.profile, foreground: false)
            guard let c = new as? ChromiumTab else { return false }
            c.getNavigationStarted = Date()
        }
        let focused = (window.firstResponder as? NSView)?.isDescendant(of: old.view) == true
        // A page in a host the app doesn't re-present (Peek's card) gets the new one in the same host.
        if let host = old.view.superview, host !== hostView, !old.view.isHidden {
            if let t = new as? WebKitTab { webKit.window.place(t, in: host) } else { (new as? ChromiumTab)?.core.attach(to: host) }
        }
        guard delegate.engineWindow(self, replace: old, with: new) else {
            new.close()
            return false
        }
        if let c = old as? ChromiumTab {
            c.retired = true
            c.core.closeNow()
        } else {
            old.close()
        }
        if focused { new.focus() }
        return true
    }

    /// A Chromium page's link (ChromiumRuntime's routeLink, before its request): to a listed site it opens in WebKit,
    /// in place for the page's own frame, as a new tab for target=_blank and ⌘-click. Popups keep Chromium (their
    /// `window.opener`), and a POST never comes here.
    func routeToWebKit(_ link: EngineLinkRequest, from page: ChromiumTab) -> Bool {
        // The engine asks for links only (never a POST): a redirect from this one to a service still moves.
        if link.disposition == "current_tab" { page.getNavigationStarted = Date() }
        guard media.sites.handoff(from: .chromium, to: link.url.absoluteString) == .webKit,
              engine.webKitProfile(for: page.profile) != nil else { return false }
        switch link.disposition {
        case "current_tab":
            guard delegate?.engineWindowCanReplaceTabs(self) == true else { return false }
            DispatchQueue.main.async { [weak self, weak page] in
                guard let self, let page, !page.isClosed else { return }
                self.reopen(page, url: link.url, in: .webKit)
            }
            return true
        case "foreground_tab", "background_tab":
            DispatchQueue.main.async { [weak self, weak page] in
                guard let self, let wk = page.flatMap({ self.engine.webKitProfile(for: $0.profile) }), let page else { return }
                let tab = self.webKit.window.openTab(url: link.url, profile: wk, hostProfile: page.profile, foreground: false)
                self.delegate?.engineWindow(self, didInsertTab: tab, opener: page,
                                            disposition: link.disposition == "background_tab" ? .background : .foreground)
            }
            return true
        default:
            return false
        }
    }

    /// A Chromium page that a GET took to a listed site anyway (a redirect after a link, the URL bar or a new tab's
    /// address: t.co, a mail app's link wrapper) opens again in WebKit at that address. Not after a form's POST (its
    /// result belongs where it was posted), a history step or a script, and never a popup (its opener needs it).
    func chromiumPageCommitted(_ page: ChromiumTab) {
        guard !page.retired, !page.isPopup, let started = page.getNavigationStarted, Date().timeIntervalSince(started) < 20,
              let url = page.url, media.engine(for: url) == .webKit,
              delegate?.engineWindowCanReplaceTabs(self) == true else { return }
        page.getNavigationStarted = nil
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self, let page, !page.retired, !page.isClosed, page.url == url else { return }
            self.reopen(page, url: url, in: .webKit)
        }
    }

    /// A WebKit page's link (WebKitWindow.linkPolicy). New tabs Airc opens follow the rules (a sign-in host stays
    /// WebKit); a link in the page's own frame stays WebKit unless the app routes it (Peek from a pinned tab).
    func webKitLink(_ tab: WebKitTab, url: URL, newTab: Bool, background: Bool) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let request = EngineLinkRequest(url: url, source: "page",
                                        disposition: newTab ? (background ? "background_tab" : "foreground_tab") : "current_tab",
                                        sourceBundleID: nil, userGesture: true, opener: tab)
        if !newTab {
            guard WindowController.crossSite(tab.url, url) else { return false }
            return ChromiumRuntime.linkRouter?(request) == true
        }
        if ChromiumRuntime.linkRouter?(request) == true { return true }
        guard media.sites.engine(forAddressBar: url.absoluteString, current: .webKit) == .chromium else { return false }
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, !tab.isClosed else { return }
            let page = self.openChromiumTab(url: url, profile: tab.profile, foreground: false)
            self.delegate?.engineWindow(self, didInsertTab: page, opener: tab, disposition: background ? .background : .foreground)
        }
        return true
    }

    /// SB-55 for a WebKit page: leaving its tab in the key window sends a playing video to the system's picture in
    /// picture, when the profile has automatic picture in picture on.
    func autoPictureInPicture(_ page: WebKitTab) {
        guard !page.isClosed, window.isKeyWindow, (page.profile as? ChromiumProfile)?.core.autoPictureInPictureEnabled == true
        else { return }
        page.evaluate("""
        (function(){ if (document.pictureInPictureElement) return 'already';
          var v = Array.prototype.find.call(document.querySelectorAll('video'), function(v){
            return !v.paused && !v.ended && v.readyState > 2 && !v.disablePictureInPicture; });
          if (!v || !v.requestPictureInPicture) return 'none';
          v.requestPictureInPicture().catch(function(){}); return 'requested'; })()
        """, completion: nil)
    }
}
#endif
