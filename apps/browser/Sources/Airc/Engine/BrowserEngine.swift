// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

// The app talks to the web engine only through these protocols. UI code never imports WebKit or
// the Chromium framework.
//
// The shape follows the engine layer's Objective-C API (engine/core/public/Airc.h) one to one, so
// `ChromiumEngine` is a thin adapter:
//
//   BrowserEngine          ↔ AircEngine          (profiles: loadProfile, deleteProfile)
//   EngineProfile          ↔ AircProfile         (one real profile: logins, cookies, history)
//   EngineWindow           ↔ AircWindow          (one per window; one browser per (window, profile))
//   EngineWindowDelegate   ↔ AircWindowDelegate  (didInsertTab: popups, ⌘-click, target=_blank)
//   EngineTab              ↔ AircTab             (+ Navigation, Page, Media categories)
//   EngineTabDelegate      ↔ AircTabDelegate
//
// `WebKitEngine` implements the same protocols with WKWebView and one WKWebsiteDataStore per
// profile, so logins are already separate per profile in the dev engine.

struct EngineLinkRequest {
    let url: URL
    let source: String
    let disposition: String
    let sourceBundleID: String?
    let userGesture: Bool
    let opener: EngineTab?
}
enum EngineHostingError: Error { case rejected(String) }

protocol BrowserEngine: AnyObject {
    /// Main-thread policy; true consumes the link. Defer tab mutation to the next turn.
    var linkRouter: ((EngineLinkRequest) -> Bool)? { get set }
    /// Call inside application(_:open:) while its Apple event is current.
    func routeExternalURL(_ url: URL) -> Bool
    /// "WebKit" or "Chromium <version>", for About and logs.
    var name: String { get }
    /// Global engine setting. Unsupported engines hide the protected-content UI.
    var supportsProtectedContent: Bool { get }
    var protectedContentEnabled: Bool { get set }
    func installedExtensions(for profile: EngineProfile) -> [[String: Any]]
    func extensionActions(_ ids: [String], for tab: EngineTab) -> [String: [String: Any]]
    func extensionActionIcon(_ state: [String: Any]) -> NSImage?
    @discardableResult func executeExtensionAction(_ id: String, for tab: EngineTab) -> String
    @discardableResult func presentExtensionAction(_ id: String, for tab: EngineTab,
                                                   anchorRect: NSRect, in view: NSView) -> Bool
    func closeExtensionPopup(in window: EngineWindow)

    var reportsPageShortcuts: Bool { get }
    /// A close the app asks for reports how it ended: completed (`tabRequestedClose`) or refused (`tabCancelledClose`,
    /// the person stayed on the page). Without it the app watches for the page's question to go away.
    var reportsCloseOutcome: Bool { get }
    /// SB-55: whether the window showing `tab` is the key window. Chromium's automatic picture-in-picture (a playing
    /// video or a call, when its tab is left) only enters for a tab switch in the active window, as in Chrome.
    func setPictureInPictureWindowActive(_ tab: EngineTab, active: Bool)
    /// Loads (or creates) the profile stored in `directory` (AircEngine -loadProfile:completion:).
    /// Directory names are fixed per profile and never reused.
    func loadProfile(directory: String, completion: @escaping (EngineProfile?) -> Void)
    /// Deletes the profile's data folder (AircEngine -deleteProfile:completion:).
    func deleteProfile(_ profile: EngineProfile, completion: @escaping (Bool) -> Void)
    /// Creates a browser window. The engine owns the NSWindow (AircWindow -initWithContentRect:);
    /// the app sets its style and content.
    func makeWindow(contentRect: NSRect) -> EngineWindow
}

extension BrowserEngine {
    var supportsProtectedContent: Bool { false }
    var protectedContentEnabled: Bool { get { false } set {} }
    var linkRouter: ((EngineLinkRequest) -> Bool)? { get { nil } set {} }
    func routeExternalURL(_ url: URL) -> Bool { false }
    func installedExtensions(for profile: EngineProfile) -> [[String: Any]] { [] }
    func extensionActions(_ ids: [String], for tab: EngineTab) -> [String: [String: Any]] { [:] }
    func extensionActionIcon(_ state: [String: Any]) -> NSImage? { nil }
    func executeExtensionAction(_ id: String, for tab: EngineTab) -> String { "none" }
    func presentExtensionAction(_ id: String, for tab: EngineTab,
                                anchorRect: NSRect, in view: NSView) -> Bool { false }
    func closeExtensionPopup(in window: EngineWindow) {}

    /// CB-3: the engine tells the app whether a page used a ⌘/⌃ shortcut (EngineTabDelegate
    /// tab(_:didReceiveShortcut:pageUsedIt:)). Without it the browser's shortcuts always come first.
    var reportsPageShortcuts: Bool { false }
    var reportsCloseOutcome: Bool { false }
    func setPictureInPictureWindowActive(_ tab: EngineTab, active: Bool) {}
}

protocol EngineProfile: AnyObject {
    var directory: String { get }
    /// Starts a renderer process so the first page of a new profile appears at once.
    func warmSpareRenderer()
    /// "Sign out everywhere / clear this profile's data" (SP-14).
    func clearBrowsingData(completion: @escaping () -> Void)
}

/// How an engine-created tab arrived (AircWindowDelegate -window:didInsertTab:opener:disposition:).
enum TabDisposition: String {
    case foreground   // target=_blank, middle-click with ⇧, "Open Link in New Tab" then switch
    case background   // ⌘-click
    case popup        // window.open with features (sign-in popups); shown as a tab (SP-3)
}

protocol EngineWindowDelegate: AnyObject {
    /// The page opened a tab. App-initiated `openTab` calls don't come back through here.
    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?,
                      disposition: TabDisposition)
    /// The page closed itself or completed a host-requested close.
    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab)
    func engineWindow(_ window: EngineWindow, tabCancelledClose tab: EngineTab)
    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool)
    /// Whether this delegate takes `replace` (below). An engine asks before it moves a page to another engine.
    func engineWindowCanReplaceTabs(_ window: EngineWindow) -> Bool
    /// The page `old` opened again as `new` in another engine (docs/user/protected-media.md: a Spotify link in a
    /// Chromium page plays in WebKit). The delegate puts `new` where `old` was (same tab, pane and focus) and returns
    /// true; the engine then closes `old` without asking it or reporting the close. False: nothing changed.
    func engineWindow(_ window: EngineWindow, replace old: EngineTab, with new: EngineTab) -> Bool
}

extension EngineWindowDelegate {
    func engineWindow(_ window: EngineWindow, tabCancelledClose tab: EngineTab) {}
    func engineWindowCanReplaceTabs(_ window: EngineWindow) -> Bool { false }
    func engineWindow(_ window: EngineWindow, replace old: EngineTab, with new: EngineTab) -> Bool { false }
}

protocol EngineWindow: AnyObject {
    /// 1–4 distinct live tabs, each in an app-owned view belonging to this window.
    /// Reuse views and resize their frames; don't call this for every divider tick.
    func presentPanes(_ panes: [(tab: EngineTab, host: NSView)], focused: EngineTab) throws
    func focusPane(_ tab: EngineTab)
    /// Same-profile transfer; wrapper, WebContents, media and delegate identity survive.
    func moveTab(_ tab: EngineTab, profile: EngineProfile, to host: NSView) throws
    func openPeek(url: URL, opener: EngineTab, in host: NSView) throws -> EngineTab
    var window: NSWindow { get }
    /// The view the engine attaches the active tab's page view to. The app lays it out inside the
    /// page card.
    var hostView: NSView { get }
    var delegate: EngineWindowDelegate? { get set }
    /// The profile whose browser is in front (AircWindow.activeProfile).
    var activeProfile: EngineProfile? { get set }
    /// Prepares this window's browser for a profile, so its first tab opens instantly.
    func prepareProfile(_ profile: EngineProfile)
    /// Opens a tab in `profile`. `url == nil` opens a blank page.
    func openTab(url: URL?, profile: EngineProfile, foreground: Bool) -> EngineTab
    /// Attaches the tab's page view to `hostView` and detaches the previous one. No reload.
    func activateTab(_ tab: EngineTab)
    /// Detaches whatever page is shown (a Space with no tab shows an empty card).
    func deactivateAll()
    func tabs(for profile: EngineProfile) -> [EngineTab]
    /// Airc's own navigation of a page (the URL bar, a pinned tab's reset). An engine that plays some sites in another
    /// engine may open the page again there (`EngineWindowDelegate.replace`); otherwise this is `tab.load(url)`.
    func load(_ url: URL, in tab: EngineTab)
}

protocol EngineTab: EnginePageCommands {
    var tabID: Int { get }
    var view: NSView { get }
    var profile: EngineProfile { get }
    var delegate: EngineTabDelegate? { get set }

    var url: URL? { get }
    var title: String { get }
    var isLoading: Bool { get }
    var progress: Double { get }
    var favicon: NSImage? { get }
    var faviconURL: URL? { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isAudible: Bool { get }
    var isMuted: Bool { get set }
    var themeColor: NSColor? { get }
    var isClosed: Bool { get }

    // Navigation
    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stop()
    // Page
    func focus()
    func evaluate(_ script: String, completion: ((Any?) -> Void)?)
    /// A picture of the page as shown, for the debug snapshot hook.
    func snapshot(completion: @escaping (NSImage?) -> Void)
    /// Frees the page but keeps the tab restorable (AircTab -discard).
    @discardableResult func discard() -> Bool
    func close()
}

/// Chrome's standard page commands (CB-2) and the unload hooks (MEM-3). An engine that lacks one keeps the default
/// here, which does nothing visible (the Chromium adapter has the engine calls in AircTab: reloadIgnoringCache,
/// zoomStep:, zoomFactor, showDevTools, find:forward:, discard).
protocol EnginePageCommands: AnyObject {
    /// ⇧⌘R: reload, bypassing the cache.
    func reloadIgnoringCache()
    /// ⌘+ / ⌘− (`step` ±1) and ⌘0 (`step` 0, back to 100 %).
    func zoom(step: Int)
    var zoomFactor: Double { get }
    /// ⌥⌘I / ⌥⌘J. Returns false when the engine can't open developer tools from a shortcut.
    func showDevTools(console: Bool) -> Bool
    /// ⌘P. Returns false when the engine can't print.
    func printPage(from window: NSWindow) -> Bool
    /// ⌘F / ⌘G: highlights the next (or previous) match; `completion(found, matches)` (matches nil when unknown).
    func find(_ text: String, forward: Bool, completion: @escaping (Bool, Int?) -> Void)
    func stopFinding()
    /// The page has typed-in form input that a reload would lose (MEM-3 never unloads such a tab).
    func hasUnsavedInput(completion: @escaping (Bool) -> Void)
    /// SB-1: the pages Back and Forward go to, nearest first (`offset` −1, −2… and 1, 2…), for their history menus.
    var history: (back: [EngineHistoryEntry], forward: [EngineHistoryEntry]) { get }
    /// Goes `offset` entries back (negative) or forward in the tab's history.
    func go(offset: Int)
}

/// One entry of a tab's back/forward history.
struct EngineHistoryEntry: Equatable {
    var offset: Int
    var url: String
    var title: String
}

extension EnginePageCommands where Self: EngineTab {
    func reloadIgnoringCache() { reload() }
    func zoom(step: Int) {}
    var zoomFactor: Double { 1 }
    func showDevTools(console: Bool) -> Bool { false }
    func printPage(from window: NSWindow) -> Bool { false }
    func find(_ text: String, forward: Bool, completion: @escaping (Bool, Int?) -> Void) { completion(false, nil) }
    func stopFinding() {}
    var history: (back: [EngineHistoryEntry], forward: [EngineHistoryEntry]) { ([], []) }
    func go(offset: Int) {
        for _ in 0..<abs(offset) { if offset < 0 { goBack() } else { goForward() } }
    }
    func hasUnsavedInput(completion: @escaping (Bool) -> Void) {
        // A form field with a typed value; checked in the page, so it works on every engine that can evaluate.
        evaluate("""
        Array.prototype.some.call(document.querySelectorAll('textarea, input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]), [contenteditable=true]'),
          function(e){ return (e.value !== undefined ? e.value !== e.defaultValue : e.textContent.length > 0) })
        """) { completion(($0 as? Bool) ?? true) }
    }
}

protocol EngineTabDelegate: AnyObject {
    func tabDidChangeTitle(_ tab: EngineTab)
    func tabDidChangeURL(_ tab: EngineTab)
    func tabDidChangeLoading(_ tab: EngineTab)
    func tabDidChangeFavicon(_ tab: EngineTab)
    func tabDidChangeNavigationState(_ tab: EngineTab)
    func tabDidChangeAudio(_ tab: EngineTab)
    func tabDidChangeThemeColor(_ tab: EngineTab)
    /// CB-3: a ⌘/⌃ shortcut reached the page; `pageUsedIt` when one of its handlers called preventDefault.
    func tab(_ tab: EngineTab, didReceiveShortcut combo: String, pageUsedIt: Bool)
}

extension EngineTabDelegate {
    func tab(_ tab: EngineTab, didReceiveShortcut combo: String, pageUsedIt: Bool) {}
}

// WebKit remains buildable; it must explicitly implement live hosting before using these UI paths.
extension EngineWindow {
    func load(_ url: URL, in tab: EngineTab) { tab.load(url) }
    func presentPanes(_ panes: [(tab: EngineTab, host: NSView)], focused: EngineTab) throws {
        throw EngineHostingError.rejected("multiPaneUnsupported")
    }
    func focusPane(_ tab: EngineTab) { tab.focus() }
    func moveTab(_ tab: EngineTab, profile: EngineProfile, to host: NSView) throws {
        throw EngineHostingError.rejected("liveMoveUnsupported")
    }
    func openPeek(url: URL, opener: EngineTab, in host: NSView) throws -> EngineTab {
        throw EngineHostingError.rejected("peekUnsupported")
    }
}
