// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

#if canImport(AircCore)
import AircCore

// Construct only from engineDidStart. AircEngine.run owns the process message loop.
final class ChromiumEngine: BrowserEngine {
    var linkRouter: ((EngineLinkRequest) -> Bool)? {
        get { ChromiumRuntime.linkRouter }
        set { ChromiumRuntime.linkRouter = newValue }
    }
    func routeExternalURL(_ url: URL) -> Bool { core.routeExternalURL(url.absoluteString) }
    let core: AircEngine
    private(set) var profiles: [ObjectIdentifier: ChromiumProfile] = [:]
    /// The WebKit pages of DRM services (HybridEngine.swift, docs/user/protected-media.md): one persistent store per
    /// profile, named from the data folder plus the profile.
    lazy var webKit = WebKitEngine(ephemeral: CommandLine.arguments.contains("--ephemeral"),
                                   storeScope: AppPaths.dataDirectory.standardizedFileURL.path)
    init() {
        precondition(Thread.isMainThread)
        guard let core = AircEngine.shared else {
            preconditionFailure("ChromiumEngine requires engineDidStart")
        }
        self.core = core
    }
    // SB-55: subscribe from the app's tab/Space model, never from Chromium UI.
    var pictureInPictureDidChange: ((EngineTab, [String: Any]) -> Void)?
    var pictureInPictureRequestsTab: ((EngineTab) -> Void)?
    func setAutoPictureInPictureEnabled(_ profile: EngineProfile, enabled: Bool) {
        (profile as? ChromiumProfile)?.core.autoPictureInPictureEnabled = enabled
    }
    func autoPictureInPictureEnabled(_ profile: EngineProfile) -> Bool {
        (profile as? ChromiumProfile)?.core.autoPictureInPictureEnabled ?? false
    }
    @discardableResult
    func setAutoPictureInPictureException(_ profile: EngineProfile, origin: String, enabled: Bool?) -> Bool {
        (profile as? ChromiumProfile)?.core.setAutoPictureInPictureException(
            origin, enabled: enabled.map { NSNumber(value: $0) }) ?? false
    }
    func setPictureInPictureFrame(_ profile: EngineProfile, frame: NSRect) {
        (profile as? ChromiumProfile)?.core.pictureInPictureFrame = frame
    }
    func pictureInPictureFrame(_ profile: EngineProfile) -> NSRect {
        (profile as? ChromiumProfile)?.core.pictureInPictureFrame ?? .zero
    }
    func setPictureInPictureWindowActive(_ tab: EngineTab, active: Bool) {
        (tab as? ChromiumTab)?.core.setPictureInPictureWindowActive(active)
    }
    func closePictureInPicture(_ tab: EngineTab) {
        (tab as? ChromiumTab)?.core.exitPictureInPicture()
    }
    // Concrete adapter hooks; the app owns BrowserEngine protocol/UI adoption.
    func queryHistory(_ query: String, for profile: EngineProfile, limit: Int = 50,
                      completion: @escaping ([[String: Any]]) -> Void) {
        guard let profile = profile as? ChromiumProfile else { completion([]); return }
        profile.core.queryHistory(query, limit: limit) { completion($0.map { $0 as? [String: Any] ?? [:] }) }
    }
    func observeHistory(for profile: EngineProfile, handler: (([String: Any]) -> Void)?) {
        (profile as? ChromiumProfile)?.core.observeHistoryVisits(handler.map { callback in
            { row in callback(row as? [String: Any] ?? [:]) }
        })
    }
    func observeDownloads(for profile: EngineProfile, handler: (([String: Any]) -> Void)?) {
        (profile as? ChromiumProfile)?.core.observeDownloads(handler.map { callback in
            { row in callback(row as? [String: Any] ?? [:]) }
        })
    }
    func googleAccounts(for profile: EngineProfile) -> [String: Any] {
        (profile as? ChromiumProfile)?.core.googleAccounts as? [String: Any] ?? ["fresh": false, "accounts": []]
    }
    func importCredentials(logins: [[String: Any]], cookies: [[String: Any]], into profile: EngineProfile,
                           completion: @escaping ([String: Any], [String: Any]) -> Void) {
        guard let profile = profile as? ChromiumProfile else {
            completion(["error": "invalid profile"], ["error": "invalid profile"]); return
        }
        profile.core.importLogins(logins) { loginResult in
            profile.core.importCookies(cookies) { cookieResult in
                completion(loginResult as? [String: Any] ?? [:], cookieResult as? [String: Any] ?? [:])
            }
        }
    }
    func setUIAnchor(window: EngineWindow, view: NSView, rect: NSRect) {
        guard let window = window as? ChromiumWindow, view.window === window.window else { return }
        window.core.uiAnchorView = view
        window.core.uiAnchorRect = rect
    }
    var contextMenuSpaces: ((EngineTab, String) -> [[String: String]])?
    var openLinkInSpace: ((EngineTab, String, String) -> Void)?
    func showDevTools(for tab: EngineTab) { _ = (tab as? ChromiumTab)?.showDevTools(console: false) }
    func closeDevTools(for tab: EngineTab) { (tab as? ChromiumTab)?.dismissDevTools() }
    /// Whether `tab` has its DevTools open (SV-1: each pane its own).
    func devToolsOpen(for tab: EngineTab) -> Bool { (tab as? ChromiumTab)?.toolsPanel != nil || (tab as? ChromiumTab)?.core.devToolsView != nil }
    func snapshotDevTools(for tab: EngineTab, completion: @escaping (NSImage?) -> Void) {
        guard let tab = tab as? ChromiumTab else { completion(nil); return }
        tab.core.copyDevToolsPicture(5) { image in
            completion(image.map { NSImage(cgImage: $0, size: .zero) })
        }
    }
    var findStateDidChange: ((EngineTab, [String: Any]) -> Void)?
    func find(_ text: String, in tab: EngineTab, forward: Bool = true) {
        (tab as? ChromiumTab)?.core.find(text, forward: forward)
    }
    func stopFinding(in tab: EngineTab) { (tab as? ChromiumTab)?.core.stopFinding() }
    func findState(for tab: EngineTab) -> [String: Any] { (tab as? ChromiumTab)?.core.findState ?? [:] }
    // Prompt dictionaries contain display state; passwords stay in Chromium unless
    // the user explicitly supplies an edited value to resolvePasswordPrompt.
    var passwordPromptDidChange: ((EngineTab, [String: Any]) -> Void)?
    var autofillPromptDidChange: ((EngineTab, [String: Any]) -> Void)?
    // Opt-in only after installing a picker. Rows contain an opaque "index" string;
    // empty rows dismiss it. Call accept after a deliberate user selection.
    var usesHostPasswordSuggestions = false
    @discardableResult func acceptAutofillSuggestion(in tab: EngineTab, index: Int) -> Bool {
        (tab as? ChromiumTab)?.core.acceptAutofillSuggestion(index) ?? false
    }
    func hideAutofillSuggestions(in tab: EngineTab) {
        (tab as? ChromiumTab)?.core.hideAutofillSuggestions()
    }
    func enterPictureInPictureForHost(_ tab: EngineTab, completion: @escaping (String, Bool) -> Void) {
        guard let tab = tab as? ChromiumTab else { completion("none", false); return }
        tab.core.enterPictureInPicture(forHost: completion)
    }
    var autofillSuggestionsDidChange: ((EngineTab, [[String: String]]) -> Void)?
    func passwordPrompt(for tab: EngineTab) -> [String: Any]? {
        (tab as? ChromiumTab)?.core.passwordPrompt
    }
    func autofillPrompt(for tab: EngineTab) -> [String: Any]? {
        (tab as? ChromiumTab)?.core.autofillPrompt
    }
    func resolvePasswordPrompt(in tab: EngineTab, action: String,
                               username: String? = nil, password: String? = nil) {
        (tab as? ChromiumTab)?.core.resolvePasswordPrompt(action, username: username, password: password)
    }
    func resolveAutofillPrompt(in tab: EngineTab, id: Int, action: String) {
        (tab as? ChromiumTab)?.core.resolveAutofillPrompt(id, action: action)
    }
    @discardableResult func showAutofillSuggestions(in tab: EngineTab, passwords: Bool) -> Bool {
        (tab as? ChromiumTab)?.core.showAutofillSuggestions(passwords) ?? false
    }
    // SB-3: a page's permission request ({id, origin, permissions}), with the page that asked. Without a subscriber
    // the runtime dismisses it (never a silent grant). `permissionRequestDismissed` is the engine withdrawing one (the
    // page navigated or closed). Resolve each id once: accept (remember false = this time only, where Chromium has
    // temporary grants), deny with remember (a persisted block), or dismiss.
    var permissionRequested: ((EngineTab, [String: Any]) -> Void)? {
        get { ChromiumRuntime.permissionHandler }
        set { ChromiumRuntime.permissionHandler = newValue }
    }
    var permissionRequestDismissed: ((String) -> Void)? {
        get { ChromiumRuntime.permissionDismissedHandler }
        set { ChromiumRuntime.permissionDismissedHandler = newValue }
    }
    func resolvePermission(_ id: String, result: String, remember: Bool) {
        AircEngine.resolvePermission(id, result: result, remember: remember)
    }
    /// The URL field's rectangle for the engine's own bubbles (PROFILE-SERVICES.md "Page/window UI"), and its screen
    /// rectangle as the engine converts it (zero for a view in another window).
    func uiAnchorRectInScreen(window: EngineWindow) -> NSRect {
        (window as? ChromiumWindow)?.core.uiAnchorRectInScreen ?? .zero
    }
    // IDC_BASIC_PRINT bypasses Chrome's Views print-preview window and invokes
    // the system print path. True means dispatched, not that printing completed.
    @discardableResult func printPage(_ tab: EngineTab) -> Bool {
        (tab as? ChromiumTab)?.core.executeChromeCommand(35007) ?? false
    }
    var discardedStateDidChange: ((EngineTab) -> Void)?
    func installedExtensions(for profile: EngineProfile) -> [[String: Any]] {
        (profile as? ChromiumProfile)?.core.extensions ?? []
    }
    func extensionActions(_ ids: [String], for tab: EngineTab) -> [String: [String: Any]] {
        let states = (tab as? ChromiumTab)?.core.actionStates(forExtensions: ids) ?? [:]
        return states.mapValues { $0 as? [String: Any] ?? [:] }
    }
    // Action state includes icon (PNG data URL), title, enabled, badgeText,
    // badgeColor and badgeTextColor. Decode locally; never fetch the icon URL.
    func extensionActionIcon(_ state: [String: Any]) -> NSImage? {
        guard let url = state["icon"] as? String,
              url.hasPrefix("data:image/png;base64,"),
              let data = Data(base64Encoded: String(url.dropFirst(22))) else { return nil }
        return NSImage(data: data)
    }
    @discardableResult func executeExtensionAction(_ id: String, for tab: EngineTab) -> String {
        (tab as? ChromiumTab)?.core.executeExtensionAction(id) ?? "none"
    }
    // This performs the action itself (including activeTab); do not call execute first.
    // False also covers a non-popup action that successfully dispatched onClicked.
    @discardableResult func presentExtensionAction(_ id: String, for tab: EngineTab,
                                                   anchorRect: NSRect, in view: NSView) -> Bool {
        guard let tab = tab as? ChromiumTab, let owner = tab.owner,
              view.window === owner.window else { return false }
        return owner.core.presentActionPopup(forExtension: id, tab: tab.core,
                                              anchorRect: anchorRect, in: view) != nil
    }
    func closeExtensionPopup(in window: EngineWindow) {
        (window as? ChromiumWindow)?.core.closeActionPopup()
    }
    #if AIRC_TESTING
    // Test hooks for the app's scripted extension run (--script extension): the same presentation with the popup's
    // rendered picture, and a DevTools protocol call into a page (real input for the Web Store's button).
    func presentExtensionActionPicture(_ id: String, for tab: EngineTab, anchorRect: NSRect, in view: NSView,
                                       completion: @escaping (NSImage?) -> Void) {
        guard let tab = tab as? ChromiumTab, let owner = tab.owner, view.window === owner.window,
              let popup = owner.core.presentActionPopup(forExtension: id, tab: tab.core, anchorRect: anchorRect, in: view)
        else { completion(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            popup.copyPicture(5) { completion($0.map { NSImage(cgImage: $0, size: .zero) }) }
        }
    }
    func devToolsCall(_ method: String, params: [String: Any]?, in tab: EngineTab,
                      completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let tab = tab as? ChromiumTab else { completion(nil, "not a Chromium tab"); return }
        tab.core.devToolsCall(method, params: params, timeout: 10) { completion($0 as? [String: Any], $1) }
    }
    // Test hooks for --script dialogs: the engine's native modal state and its dialog's Cancel handler. Empty / false
    // unless the app runs with --airc-test=modalDialogs under the engine's scratch, mock-keychain test gate.
    func modalDialogState(for tab: EngineTab) -> [String: Any] {
        (tab as? ChromiumTab)?.core.modalDialogStateForTesting() as? [String: Any] ?? [:]
    }
    @discardableResult func cancelModalDialog(in tab: EngineTab) -> Bool {
        (tab as? ChromiumTab)?.core.cancelModalDialogForTesting() ?? false
    }
    #endif
    func setUnloadTimeout(_ seconds: TimeInterval, for profile: EngineProfile) {
        (profile as? ChromiumProfile)?.core.unloadTimeout = seconds
    }
    func isDiscarded(_ tab: EngineTab) -> Bool { (tab as? ChromiumTab)?.core.discarded ?? false }
    @discardableResult func discard(_ tab: EngineTab) -> Bool { (tab as? ChromiumTab)?.core.discard() ?? false }
    var reportsPageShortcuts: Bool { true }
    /// Engine pass 12: tabDidCloseForHost / tabDidCancelClose.
    var reportsCloseOutcome: Bool { true }
    var name: String { "Chromium \(core.chromiumVersion)" }
    fileprivate func wrap(_ profile: AircProfile) -> ChromiumProfile {
        let key = ObjectIdentifier(profile)
        if let existing = profiles[key] { return existing }
        let result = ChromiumProfile(profile)
        profiles[key] = result
        return result
    }
    func loadProfile(directory: String, completion: @escaping (EngineProfile?) -> Void) {
        core.loadProfile(directory: directory) { [self] profile in
            completion(profile.map(wrap))
        }
    }
    /// Cleanup only: rejects default and any profile loaded during this engine session.
    func deleteUnloadedProfile(directory: String, completion: @escaping ([String: Any]) -> Void) {
        core.deleteUnloadedProfile(directory: directory) { [self] result in
            let result = result as? [String: Any] ?? ["deleted": false, "reason": "invalid engine response"]
            if result["deleted"] as? Bool == true { deleteWebKitData(directory: directory) { _ in } }
            completion(result)
        }
    }
    func deleteProfile(_ profile: EngineProfile, completion: @escaping (Bool) -> Void) {
        guard let profile = profile as? ChromiumProfile else { completion(false); return }
        let directory = profile.directory
        core.delete(profile.core) { [self] accepted in
            if accepted {
                // Its WebKit pages' cookies and storage go with it.
                deleteWebKitData(directory: directory) { _ in }
                profiles.removeValue(forKey: ObjectIdentifier(profile.core))
            }
            completion(accepted)
        }
    }
    func makeWindow(contentRect: NSRect) -> EngineWindow {
        let window = NSWindow(contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = PageHostView(frame: .zero)
        return ChromiumWindow(engine: self, core: AircWindow(window: window, hostView: page))
    }
}

final class ChromiumProfile: EngineProfile {
    let core: AircProfile
    /// Its WebKit pages' profile and observers (HybridEngine.swift).
    let hybrid = HybridProfileState()
    init(_ core: AircProfile) { self.core = core }
    var directory: String { URL(fileURLWithPath: core.path).lastPathComponent }
    func warmSpareRenderer() { core.warmSpareRenderer() }
    func clearBrowsingData(completion: @escaping () -> Void) {
        core.clearBrowsingData(["history", "siteData", "cache", "downloads"], since: nil,
                               completion: completion)
    }
}

final class ChromiumWindow: NSObject, EngineWindow, AircWindowDelegate {
    let engine: ChromiumEngine
    let core: AircWindow
    /// Its WebKit pages (HybridEngine.swift): the EngineWindow calls below choose an engine per page and go to the
    /// Chromium-only ones (`openChromiumTab`…) or to this.
    lazy var webKit = HybridWebKitSide(window: self)
    // Identity must survive callbacks; UI owns tab models independently of the active page.
    private var wrappedTabs: [ObjectIdentifier: ChromiumTab] = [:]
    private var selected: ChromiumTab?
    weak var delegate: EngineWindowDelegate?
    init(engine: ChromiumEngine, core: AircWindow) {
        self.engine = engine
        self.core = core
        super.init()
        core.delegate = self
    }
    var window: NSWindow { core.window }
    // Dedicated page container: never detach the app's sidebar/root view.
    var hostView: NSView { core.hostView }
    var activeProfile: EngineProfile? {
        get { core.activeProfile.map(engine.wrap) }
        set { core.activeProfile = (newValue as? ChromiumProfile)?.core }
    }
    func prepareProfile(_ profile: EngineProfile) {
        guard let profile = profile as? ChromiumProfile else { return }
        core.prepareProfile(profile.core)
    }
    fileprivate func wrap(_ tab: AircTab) -> ChromiumTab? {
        let key = ObjectIdentifier(tab)
        if let existing = wrappedTabs[key] { return existing }
        guard let profile = tab.profile else {
            NSLog("Airc: ignoring tab callback after its profile was destroyed")
            return nil
        }
        let result = ChromiumTab(core: tab, profile: engine.wrap(profile), owner: self)
        wrappedTabs[key] = result
        return result
    }
    func openChromiumTab(url: URL?, profile: EngineProfile, foreground: Bool) -> EngineTab {
        guard let chromiumProfile = profile as? ChromiumProfile else {
            return FailedChromiumTab(profile: profile, url: url)
        }
        var tab = core.openTab(url: url?.absoluteString ?? "about:blank",
                               profile: chromiumProfile.core, foreground: foreground)
        if tab == nil {
            NSLog("Airc: tab open failed; preparing profile Browser and retrying once")
            core.prepareProfile(chromiumProfile.core)
            tab = core.openTab(url: url?.absoluteString ?? "about:blank",
                               profile: chromiumProfile.core, foreground: foreground)
        }
        guard let tab, let result = wrap(tab) else {
            return FailedChromiumTab(profile: profile, url: url)
        }
        if foreground { activateTab(result) }
        return result
    }
    /// The Chromium panes of a split (HybridEngine.swift checks the whole split first); `focused` may be another
    /// engine's page.
    func presentChromiumPanes(_ panes: [(tab: EngineTab, host: NSView)], focused: EngineTab) throws {
        let tabs = panes.compactMap { $0.tab as? ChromiumTab }
        guard panes.count <= 4, tabs.count == panes.count,
              Set(tabs.map { ObjectIdentifier($0) }).count == panes.count,
              Set(panes.map { ObjectIdentifier($0.host) }).count == panes.count,
              tabs.allSatisfy({ $0.owner === self && !$0.isClosed }),
              panes.allSatisfy({ $0.host.window === window }) else {
            throw EngineHostingError.rejected("invalidPanes")
        }
        for tab in wrappedTabs.values where !tabs.contains(where: { $0 === tab }) {
            tab.core.setPageVisible(false)
        }
        for (index, pane) in panes.enumerated() {
            tabs[index].core.independentZoom = true
            tabs[index].core.attach(to: pane.host)
        }
        if tabs.contains(where: { $0 === focused }) { focusChromiumPane(focused) } else { selected = nil }
    }
    func focusChromiumPane(_ tab: EngineTab) {
        guard let tab = tab as? ChromiumTab, tab.owner === self, tab.core.pageVisible else { return }
        selected = tab
        core.activate(tab.core)
        tab.core.focus()
    }
    func moveChromiumTab(_ tab: EngineTab, profile: EngineProfile, to host: NSView) throws {
        guard let tab = tab as? ChromiumTab, let profile = profile as? ChromiumProfile else {
            throw EngineHostingError.rejected("wrongEngine")
        }
        if let error = core.moveTab(tab.core, profile: profile.core, to: host) {
            throw EngineHostingError.rejected(error)
        }
        let key = ObjectIdentifier(tab.core)
        if let old = tab.owner, old !== self {
            old.wrappedTabs.removeValue(forKey: key)
            if old.selected === tab { old.selected = nil }
        }
        tab.owner = self
        wrappedTabs[key] = tab
    }
    func openChromiumPeek(url: URL, opener: EngineTab, in host: NSView) throws -> EngineTab {
        guard let opener = opener as? ChromiumTab,
              let tab = core.openPeek(url: url.absoluteString, opener: opener.core, in: host) else {
            throw EngineHostingError.rejected("invalidPeek")
        }
        guard let result = wrap(tab) else { throw EngineHostingError.rejected("closedTab") }
        return result
    }
    func activateChromiumTab(_ tab: EngineTab) {
        if let failed = tab as? FailedChromiumTab {
            deactivateChromium()
            failed.view.frame = hostView.bounds
            failed.view.autoresizingMask = [.width, .height]
            hostView.addSubview(failed.view)
            return
        }
        hostView.subviews.filter { $0.identifier?.rawValue == "failedChromiumPage" }.forEach { $0.removeFromSuperview() }
        guard let tab = tab as? ChromiumTab, tab.owner === self, !tab.isClosed else { return }
        // Returning to normal presentation hides every other pane/overlay.
        wrappedTabs.values.filter { $0 !== tab }.forEach { $0.core.setPageVisible(false) }
        selected = tab
        core.activate(tab.core)
        tab.core.attach(to: hostView)
        // Do not steal first responder from the command bar. UI calls focus() explicitly.
    }
    func deactivateChromium() {
        core.closeActionPopup()
        wrappedTabs.values.forEach { $0.core.setPageVisible(false) }
        core.activeProfile = nil
        selected = nil
    }
    /// Hides every Chromium page but keeps the active profile (a WebKit page is shown).
    func hideChromiumPages() {
        core.closeActionPopup()
        wrappedTabs.values.forEach { $0.core.setPageVisible(false) }
        selected = nil
    }
    func chromiumTabs(for profile: EngineProfile) -> [EngineTab] {
        guard let profile = profile as? ChromiumProfile else { return [] }
        return core.tabs(for: profile.core).compactMap(wrap)
    }
    func window(_ window: AircWindow, passwordPrompt prompt: [String: Any], for tab: AircTab) {
        guard let tab = wrap(tab) else { return }
        engine.passwordPromptDidChange?(tab, prompt)
    }
    func window(_ window: AircWindow, autofillPrompt prompt: [String: Any], for tab: AircTab) {
        guard let tab = wrap(tab) else { return }
        engine.autofillPromptDidChange?(tab, prompt)
    }
    func window(_ window: AircWindow, didInsert tab: AircTab, opener: AircTab?, disposition: String) {
        guard let result = wrap(tab) else { return }
        result.isPopup = disposition == "popup"
        if disposition == "foreground_tab" || disposition == "background_tab" { result.getNavigationStarted = Date() }
        let source = opener.flatMap(wrap)
        // TabStripModel observers cannot synchronously mutate the tab strip.
        DispatchQueue.main.async { [weak self] in
            guard let self, !result.isClosed else { return }
            self.delegate?.engineWindow(self, didInsertTab: result, opener: source,
                disposition: disposition == "popup" ? .popup : disposition == "background_tab" ? .background : .foreground)
        }
    }
    func window(_ window: AircWindow, didRemove tab: AircTab) {
        let key = ObjectIdentifier(tab)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Moved out and straight back (moveTab): still ours.
            if let profile = tab.profile, self.core.tabs(for: profile).contains(where: { $0 === tab }) { return }
            if self.selected?.core === tab { self.selected = nil }
            self.wrappedTabs.removeValue(forKey: key)
        }
    }
    fileprivate func pageClosed(_ tab: ChromiumTab) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !tab.retired else { return }
            self.delegate?.engineWindow(self, tabRequestedClose: tab)
        }
    }
    func window(_ window: AircWindow, tab: AircTab, didChangeFullscreen fullscreen: Bool) {
        guard let tab = wrap(tab) else { return }
        delegate?.engineWindow(self, tab: tab, didChangeFullscreen: fullscreen)
    }
    /// A key the page didn't use, before the engine tries the main menu (Chrome's delayed ⌘← ⌘→, Commands.swift).
    func window(_ window: AircWindow, handleKeyEvent event: NSEvent) -> Bool { KeyMonitor.pageDidNotUse(event) }
}

// Preserve the nonoptional EngineWindow contract without creating a page in the
// wrong profile. Keep the metadata; the page can be recreated after recovery.
private final class FailedChromiumTab: EngineTab {
    let profile: EngineProfile
    let url: URL?
    let view = NSView()
    weak var delegate: EngineTabDelegate?
    init(profile: EngineProfile, url: URL?) {
        self.profile = profile
        self.url = url
        view.identifier = NSUserInterfaceItemIdentifier("failedChromiumPage")
        let message = NSTextField(labelWithString: "Unable to open page. Close this tab and try again.")
        message.frame = NSRect(x: 24, y: 24, width: 500, height: 24)
        view.addSubview(message)
        NSLog("Airc: unable to open Chromium tab after recovery; keeping tab metadata for retry")
    }
    let tabID = -1
    let title = "Unable to open page"
    let isClosed = true
    let isLoading = false
    let progress = 0.0
    var favicon: NSImage? { nil }
    var faviconURL: URL? { nil }
    var themeColor: NSColor? { nil }
    let canGoBack = false
    let canGoForward = false
    let isAudible = false
    var isMuted = false
    func load(_ url: URL) {}
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stop() {}
    func focus() {}
    func evaluate(_ script: String, completion: ((Any?) -> Void)?) { completion?(nil) }
    func snapshot(completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func discard() -> Bool { false }
    func close() {}
}

final class ChromiumTab: NSObject, EngineTab, AircTabDelegate {
    let core: AircTab
    let profile: EngineProfile
    weak var owner: ChromiumWindow?
    /// Replaced by a WebKit page (HybridEngine.swift): its close isn't reported.
    var retired = false
    /// Opened by a page as a popup: it keeps Chromium (its opener talks to it).
    var isPopup = false
    /// When this page last started a navigation known to be a GET (a link, the URL bar, a new tab's address): a
    /// redirect from it to a DRM service moves the page to WebKit (HybridEngine.swift); a form's POST result never does.
    var getNavigationStarted: Date?
    weak var delegate: EngineTabDelegate?
    init(core: AircTab, profile: EngineProfile, owner: ChromiumWindow) {
        self.core = core
        self.profile = profile
        self.owner = owner
        super.init()
        core.delegate = self
    }
    var tabID: Int { Int(core.tabId) }
    var view: NSView { core.view }
    var url: URL? { URL(string: core.url) }
    var title: String { core.title }
    var isLoading: Bool { core.loading }
    var progress: Double { core.progress }
    var favicon: NSImage? { core.favicon }
    var faviconURL: URL? { core.faviconURL.flatMap(URL.init(string:)) }
    var canGoBack: Bool { core.canGoBack }
    var canGoForward: Bool { core.canGoForward }
    var isAudible: Bool { core.audible }
    var isMuted: Bool { get { core.muted } set { core.muted = newValue } }
    var isClosed: Bool { core.closed }
    var themeColor: NSColor? {
        guard let hex = core.themeColor, hex.hasPrefix("#"), hex.count == 7,
              let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    func load(_ url: URL) { core.loadURL(url.absoluteString, userInitiated: true) }
    func goBack() { core.goBack() }
    func goForward() { core.goForward() }
    func reload() { core.reload() }
    func reloadIgnoringCache() { core.reloadIgnoringCache() }
    var history: (back: [EngineHistoryEntry], forward: [EngineHistoryEntry]) {
        let all = core.navigationEntries
        guard let current = all.firstIndex(where: { ($0["current"] as? Bool) == true }) else { return ([], []) }
        let entry = { (i: Int) in
            EngineHistoryEntry(offset: i - current, url: all[i]["url"] as? String ?? "", title: all[i]["title"] as? String ?? "")
        }
        return (stride(from: current - 1, through: 0, by: -1).map(entry), (current + 1 ..< all.count).map(entry))
    }
    func go(offset: Int) { core.go(toOffset: Int32(offset)) }
    func zoom(step: Int) { core.zoomStep(Int32(step.signum())) }
    var zoomFactor: Double { core.zoomFactor }
    fileprivate private(set) var toolsPanel: ChromiumToolsPanel?
    func showDevTools(console: Bool) -> Bool {
        guard !isClosed else { return false }
        if !console, toolsPanel != nil { dismissDevTools(); return true }
        guard core.executeChromeCommand(console ? 40005 : 40237) else { return false }
        attachDevTools(attempt: 0)
        return true
    }
    private func attachDevTools(attempt: Int) {
        guard !isClosed, let owner else { return }
        if let view = core.devToolsView {
            if toolsPanel == nil {
                let panel = ChromiumToolsPanel(tab: core, parent: owner.window)
                toolsPanel = panel
                panel.onClose = { [weak self, weak panel] in
                    if self?.toolsPanel === panel { self?.toolsPanel = nil }
                }
            }
            toolsPanel?.show(view)
        } else if attempt < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.attachDevTools(attempt: attempt + 1)
            }
        }
    }
    fileprivate func dismissDevTools() {
        toolsPanel?.panel.close()
        toolsPanel = nil
        core.closeDevTools()
    }
    func printPage(from window: NSWindow) -> Bool {
        guard owner?.window === window else { return false }
        return core.executeChromeCommand(35007) // IDC_BASIC_PRINT
    }
    private var findCompletion: ((Bool, Int?) -> Void)?
    func find(_ text: String, forward: Bool, completion: @escaping (Bool, Int?) -> Void) {
        guard !isClosed, !text.isEmpty else { stopFinding(); completion(false, 0); return }
        findCompletion = completion
        core.find(text, forward: forward)
    }
    func stopFinding() {
        findCompletion = nil
        core.stopFinding()
    }
    func stop() { core.stop() }
    func focus() { core.focus() }
    private static let evalBlocked = "__aircEvalBlocked"
    func evaluate(_ script: String, completion: ((Any?) -> Void)?) {
        // The core accepts a function body with post(kind, json), not an expression.
        // Quote the source as JSON so arbitrary quotes/newlines cannot break the wrapper.
        let data = try! JSONSerialization.data(withJSONObject: [script])
        let source = String(data: data, encoding: .utf8)!
        // A page whose CSP or Trusted Types refuse eval (Google's sign-in pages) says so instead of null.
        let body = "Promise.resolve().then(() => (0, eval)(\(source)[0])).then(value => post('result', JSON.stringify(value) ?? 'null'))"
            + ".catch(e => post('result', JSON.stringify({\(Self.evalBlocked): e instanceof EvalError || /unsafe-eval|TrustedScript|Content Security Policy/.test(String(e))})));"
        var answered = false
        func finish(_ value: Any?) {
            guard !answered else { return }
            answered = true
            completion?(value)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(nil) }
        core.evaluate(body) { [core] json in
            let value = json.flatMap { $0.data(using: .utf8) }.flatMap {
                try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
            }
            guard let blocked = (value as? [String: Any])?[Self.evalBlocked] as? Bool else { return finish(value) }
            guard blocked else { return finish(nil) }   // the script itself threw
            // DevTools evaluates outside the page's CSP (onboarding reads Google's ListAccounts page this way).
            core.devToolsCall("Runtime.evaluate", params: ["expression": script, "returnByValue": true, "awaitPromise": true],
                              timeout: 8) { reply, _ in
                finish(((reply as? [String: Any])?["result"] as? [String: Any])?["value"])
            }
        }
    }
    func snapshot(completion: @escaping (NSImage?) -> Void) {
        core.copyPicture(5) { picture in
            completion(picture.map { NSImage(cgImage: $0, size: .zero) })
        }
    }
    @discardableResult func discard() -> Bool { core.discard() }
    func close() { dismissDevTools(); findCompletion = nil; core.close() }
    func tab(_ tab: AircTab, spacesForContextMenuLink url: String) -> [[AnyHashable: Any]] {
        (owner?.engine.contextMenuSpaces?(self, url) ?? []).map { Dictionary<AnyHashable, Any>(uniqueKeysWithValues: $0.map { (AnyHashable($0.key), $0.value as Any) }) }
    }
    func tab(_ tab: AircTab, openContextMenuLink url: String, inSpace spaceID: String) {
        owner?.engine.openLinkInSpace?(self, url, spaceID)
    }
    func tab(_ tab: AircTab, didFindMatches count: Int32, active: Int32, final: Bool) {
        if final {
            let completion = findCompletion
            findCompletion = nil
            completion?(count > 0, max(0, Int(count)))
        }
        owner?.engine.findStateDidChange?(self, tab.findState)
    }
    func tab(_ tab: AircTab, didReceiveShortcut combo: String, pageUsedIt: Bool) {
        // Unconsumed keys may synchronously return through AppKit's menu. Let
        // menuFired cancel its pending command before reporting the ACK.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.delegate?.tab(self, didReceiveShortcut: combo, pageUsedIt: pageUsedIt)
        }
    }
    func tabDidChangeDiscarded(_ tab: AircTab) { owner?.engine.discardedStateDidChange?(self) }
    func tabWillClose(_ tab: AircTab) { dismissDevTools(); owner?.pageClosed(self) }
    func tabDidClose(forHost tab: AircTab) { dismissDevTools(); owner?.pageClosed(self) }
    func tabDidCancelClose(_ tab: AircTab) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let owner = self.owner else { return }
            owner.delegate?.engineWindow(owner, tabCancelledClose: self)
        }
    }
    func tabWantsPasswordSuggestions(_ tab: AircTab) -> Bool {
        owner?.engine.usesHostPasswordSuggestions == true
    }
    func tabDidChangeTitle(_ tab: AircTab) { delegate?.tabDidChangeTitle(self) }
    func tabDidChangeURL(_ tab: AircTab) {
        delegate?.tabDidChangeURL(self)
        owner?.chromiumPageCommitted(self)
    }
    func tabDidChangeLoading(_ tab: AircTab) {
        if !tab.loading { getNavigationStarted = nil }   // that navigation is over; a later POST's result stays
        delegate?.tabDidChangeLoading(self)
    }
    func tabDidChangeProgress(_ tab: AircTab) { delegate?.tabDidChangeLoading(self) }
    func tab(_ tab: AircTab, didShowAutofillSuggestions items: [[String: String]]) {
        owner?.engine.autofillSuggestionsDidChange?(self, items)
    }
    func tab(_ tab: AircTab, didChangePictureInPicture state: [String: Any]) {
        owner?.engine.pictureInPictureDidChange?(self, state)
    }
    func tab(_ tab: AircTab, requestsActivation reason: String) {
        if reason == "page", core.pageVisible { owner?.focusPane(self) }
        else { owner?.engine.pictureInPictureRequestsTab?(self) }
    }
    func tabDidChangeFavicon(_ tab: AircTab) { delegate?.tabDidChangeFavicon(self) }
    func tabDidChangeNavigationState(_ tab: AircTab) { delegate?.tabDidChangeNavigationState(self) }
    func tab(_ tab: AircTab, didChangeMediaAccess access: [String: NSNumber]) {
        ChromiumSiteActivity.mediaChanged(self, core: tab, access: access)
    }
    func tab(_ tab: AircTab, didBlockPopup popup: [String: String]) {
        ChromiumSiteActivity.popupBlocked(self, core: tab, popup: popup)
    }
    func tabDidChangeZoom(_ tab: AircTab) { ChromiumSiteActivity.changed(self) }
    func tabDidChangeSecurity(_ tab: AircTab) { ChromiumSiteActivity.changed(self) }
    func tabDidChangeAudio(_ tab: AircTab) { delegate?.tabDidChangeAudio(self) }
    func tabDidChangeThemeColor(_ tab: AircTab) { delegate?.tabDidChangeThemeColor(self) }
}
// Chromium's docked DevTools view needs a native host in Airc. Keep it in an
// owned utility panel; a successful command dispatch alone would leave it hidden.
private final class ChromiumToolsPanel: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let tab: AircTab
    private weak var parentWindow: NSWindow?
    var onClose: (() -> Void)?
    init(tab: AircTab, parent: NSWindow) {
        self.tab = tab
        self.parentWindow = parent
        panel = NSPanel(contentRect: NSRect(x: parent.frame.minX + 40, y: parent.frame.minY + 40,
                                           width: 900, height: 500),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Developer Tools"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        parent.addChildWindow(panel, ordered: .above)
    }
    func show(_ view: NSView) {
        guard let host = panel.contentView else { return }
        if view.superview !== host {
            tab.attachDevTools(to: host)
        }
        if parentWindow?.isKeyWindow == true || panel.isKeyWindow {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFront(nil) // Background tests must not activate the app.
        }
    }
    func windowWillClose(_ notification: Notification) {
        tab.closeDevTools()
        let callback = onClose
        DispatchQueue.main.async { callback?() }
    }
    deinit { panel.orderOut(nil) }
}
// Minimal startup bridge. Product permission/chooser UI must replace the default
// dismissals below before daily use. Never silently grant a page permission.
final class ChromiumRuntime: NSObject, AircEngineDelegate {
    static var linkRouter: ((EngineLinkRequest) -> Bool)?
    func engine(_ engine: AircEngine, routeLink request: [String: Any], opener: AircTab?) -> Bool {
        guard let raw = request["url"] as? String, let url = URL(string: raw) else { return false }
        let link = EngineLinkRequest(url: url,
            source: request["source"] as? String ?? "page",
            disposition: request["disposition"] as? String ?? "foreground_tab",
            sourceBundleID: request["sourceBundleID"] as? String,
            userGesture: request["userGesture"] as? Bool ?? false,
            opener: opener?.delegate as? ChromiumTab)
        if Self.linkRouter?(link) == true { return true }
        // A page's link to a DRM service plays in WebKit (HybridEngine.swift).
        guard link.source == "page", let page = link.opener as? ChromiumTab, let window = page.owner else { return false }
        return window.routeToWebKit(link, from: page)
    }
    private let started: () -> Void
    init(started: @escaping () -> Void) { self.started = started }
    static func closeWindow(_ window: EngineWindow) -> Bool {
        guard let window = window as? ChromiumWindow else { return true }
        window.core.close()
        return false // The engine closes the NSWindow after cancellable beforeunload.
    }
    static var requested: Bool {
        let args = CommandLine.arguments
        return args.contains("--engine=chromium") || args.indices.contains {
            args[$0] == "--engine" && $0 + 1 < args.count && args[$0 + 1] == "chromium"
        }
    }
    static func run(arguments: [String] = CommandLine.arguments, started: @escaping () -> Void) -> Int32 {
        precondition(!arguments.isEmpty && arguments.allSatisfy { !$0.contains("\0") })
        let delegate = ChromiumRuntime(started: started)
        let strings = arguments.map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var arguments: [UnsafePointer<CChar>?] = strings.map { UnsafePointer<CChar>($0) } + [nil]
        return arguments.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>.self, capacity: buffer.count) {
                AircEngine.run(argc: Int32(strings.count), argv: $0, delegate: delegate)
            }
        }
    }
    func engineDidStart() { started() }
    static var memoryPressureHandler: ((Int) -> Void)?
    func engine(_ engine: AircEngine, memoryPressure level: Int) {
        Self.memoryPressureHandler?(level)
    }
    func engineWillShutDown() { Self.memoryPressureHandler = nil }
    func engineQuitCancelled() {}
    func engineWindowForNewBrowser(of profile: AircProfile, type: String) -> AircWindow? { nil }
    /// SB-3: the app's prompt presenter (PagePrompts.swift). Without one every request is dismissed.
    static var permissionHandler: ((EngineTab, [String: Any]) -> Void)?
    static var permissionDismissedHandler: ((String) -> Void)?
    func engine(_ engine: AircEngine, permissionRequest request: [String: Any], tab: AircTab) {
        guard let id = request["id"] as? String else { return }
        // The tab's delegate is its Swift wrapper (ChromiumTab sets itself), the page the app knows.
        guard let handler = Self.permissionHandler, let page = tab.delegate as? ChromiumTab, !page.isClosed else {
            AircEngine.resolvePermission(id, result: "dismiss", remember: false)
            return
        }
        handler(page, request)
    }
    func engine(_ engine: AircEngine, permissionRequestDismissed requestId: String) {
        Self.permissionDismissedHandler?(requestId)
    }
    func engine(_ engine: AircEngine, extensionSidePanel panel: [String: Any], tab: AircTab) {}
    func engine(_ engine: AircEngine, extensionActionPopup popup: [String: Any], tab: AircTab) -> Bool { false }
    func engine(_ engine: AircEngine, extensionActionShortcut shortcut: [String: Any], tab: AircTab) -> Bool { false }
    func engineIsReservedKeyEvent(_ event: NSEvent) -> Bool { false }
    func engineIsReservedKey(_ key: String, unshiftedKey: String, modifiers: NSEvent.ModifierFlags) -> Bool { false }
    /// The app's install review (Extensions.swift). Without one every install is refused.
    static var extensionInstallHandler: (([String: Any], @escaping (Bool) -> Void) -> Void)?
    static var extensionInstallFailedHandler: ((String) -> Void)?
    func engine(_ engine: AircEngine, extensionInstallPrompt prompt: [String: Any], profile: AircProfile, tab: AircTab?) {
        guard let id = prompt["requestId"] as? String else { return }
        guard let handler = Self.extensionInstallHandler else { AircEngine.resolveExtensionInstallPrompt(id, accepted: false); return }
        handler(prompt) { AircEngine.resolveExtensionInstallPrompt(id, accepted: $0) }
    }
    func engine(_ engine: AircEngine, extensionInstallFailed message: String, tab: AircTab?) {
        Self.extensionInstallFailedHandler?(message)
    }
    func engine(_ engine: AircEngine, deviceChooser chooser: [String: Any], tab: AircTab) {
        if let id = chooser["id"] as? NSNumber { AircEngine.cancelDeviceChooser(id.int32Value) }
    }
    func engine(_ engine: AircEngine, castDialog dialog: [String: Any], tab: AircTab) {}
    func engine(_ engine: AircEngine, castRoutes routes: [[String: String]], profile: AircProfile) {}
}

// Engine pass 13's adapter (ChromiumEngine+Library.swift) and the call window (Call/CallWindow.swift): the engine
// objects behind the wrappers, an engine window around a window the app made, and the engine's question before a close
// or quit would cancel downloads.
extension ChromiumEngine {
    func core(of profile: EngineProfile) -> AircProfile? { (profile as? ChromiumProfile)?.core }
    func core(of tab: EngineTab) -> AircTab? { (tab as? ChromiumTab)?.core }
    func makeWindow(hosting window: NSWindow) -> EngineWindow {
        window.isReleasedWhenClosed = false
        return ChromiumWindow(engine: self, core: AircWindow(window: window, hostView: PageHostView(frame: .zero)))
    }
}

extension ChromiumWindow {
    @objc func window(_ window: AircWindow, confirmCloseWithDownloads count: Int32, completion: @escaping (Bool) -> Void) {
        guard let ask = ChromiumRuntime.downloadsCloseConfirmation else { return completion(true) }
        ask(Int(count), completion)
    }
}

// The page script's posts (ChromiumEngine+PageScripts.swift; Boosts).
extension ChromiumTab {
    @objc func tab(_ tab: AircTab, didReceivePageMessage kind: String, json: String, frame: String, main: Bool, origin: String) {
        ChromiumPageScripts.received(self, kind: kind, json: json, frame: frame, main: main, origin: origin)
    }
}

// Private windows (Browser/PrivateWindow.swift): the off-the-record profile of a Space's profile, one per profile while
// any private window uses it (Chrome's incognito session), destroyed after the last one closes.
extension ChromiumEngine {
    func offTheRecordProfile(for profile: EngineProfile, completion: @escaping (EngineProfile?) -> Void) {
        guard let p = profile as? ChromiumProfile else { return completion(nil) }
        core.offTheRecordProfile(for: p.core) { [self] otr, error in
            if let error { NSLog("Airc: no off-the-record profile: \(error)") }
            guard let otr else { return completion(nil) }
            let w = wrap(otr)
            // Its DRM pages (HybridEngine.swift) get a store of their own that never touches the disk: by its folder
            // name, an off-the-record profile would get its parent's persistent store.
            if w.hybrid.webKit == nil { w.hybrid.webKit = webKit.makePrivateProfile() }
            completion(w)
        }
    }
    /// The engine destroys it once no window uses it any more; calling again after that does nothing.
    func releaseOffTheRecordProfile(_ profile: EngineProfile) {
        guard let p = profile as? ChromiumProfile, p.core.offTheRecord else { return }
        profiles.removeValue(forKey: ObjectIdentifier(p.core))
        p.hybrid.webKit = nil
        core.release(p.core)
    }
    func isDestroyed(_ profile: EngineProfile) -> Bool { (profile as? ChromiumProfile)?.core.destroyed ?? true }
}
#endif
