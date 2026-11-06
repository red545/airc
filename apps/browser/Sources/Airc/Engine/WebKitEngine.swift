// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import CryptoKit
import WebKit

// The dev engine: WKWebView, one WKWebsiteDataStore per profile. This is the only file that
// imports WebKit.

final class WebKitEngine: BrowserEngine {
    /// Snapshot runs use throwaway data stores (still one per profile, so still separate).
    let ephemeral: Bool
    private var profiles: [String: WebKitProfile] = [:]

    init(ephemeral: Bool) {
        self.ephemeral = ephemeral
    }

    var name: String { "WebKit (dev engine)" }
    var reportsPageShortcuts: Bool { true }

    func loadProfile(directory: String, completion: @escaping (EngineProfile?) -> Void) {
        if let p = profiles[directory] { return completion(p) }
        let store: WKWebsiteDataStore = ephemeral
            ? .nonPersistent()
            : WKWebsiteDataStore(forIdentifier: Self.storeIdentifier(for: directory))
        let p = WebKitProfile(directory: directory, dataStore: store)
        profiles[directory] = p
        completion(p)
    }

    func deleteProfile(_ profile: EngineProfile, completion: @escaping (Bool) -> Void) {
        guard let p = profile as? WebKitProfile else { return completion(false) }
        profiles[p.directory] = nil
        if ephemeral { return completion(true) }
        WKWebsiteDataStore.remove(forIdentifier: Self.storeIdentifier(for: p.directory)) { error in
            completion(error == nil)
        }
    }

    func makeWindow(contentRect: NSRect) -> EngineWindow {
        WebKitWindow(contentRect: contentRect)
    }

    /// A stable UUID per profile folder name (WebKit names data stores by UUID).
    static func storeIdentifier(for directory: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("airc-profile:" + directory).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5 style
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

final class WebKitProfile: EngineProfile {
    let directory: String
    let dataStore: WKWebsiteDataStore
    /// Shared by every tab of the profile, including popups WebKit creates from it.
    let userContent = WKUserContentController()
    let router = ScriptRouter()
    /// Downloads and Media Session tabs (WebKitEngine+Library.swift).
    private(set) lazy var library = WebKitLibrary(profile: self)

    init(directory: String, dataStore: WKWebsiteDataStore) {
        self.directory = directory
        self.dataStore = dataStore
        userContent.addUserScript(WKUserScript(source: Self.audioScript, injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: false))
        userContent.add(router, name: "aircAudio")
        userContent.addUserScript(WKUserScript(source: Self.keysScript, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false))
        userContent.add(router, name: "aircKeys")
        library.installMediaBridge()
        WebKitPageScripts.shared.attach(self)
    }

    func warmSpareRenderer() {}

    func clearBrowsingData(completion: @escaping () -> Void) {
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast,
                             completionHandler: completion)
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        c.userContentController = userContent
        c.preferences.isElementFullscreenEnabled = true
        c.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        c.allowsAirPlayForMediaPlayback = true
        return c
    }

    /// CB-3: after a ⌘/⌃ shortcut reaches the page, reports whether the page used it (`preventDefault`), once every
    /// handler has run. The app then runs the browser's command, or waits for a second press.
    static let keysScript = """
    (function(){
      if (window.__aircKeys) return; window.__aircKeys = true;
      window.addEventListener('keydown', function(e){
        if (!(e.metaKey || e.ctrlKey)) return;
        var combo = (e.metaKey ? 'cmd+' : '') + (e.ctrlKey ? 'ctrl+' : '') + (e.altKey ? 'alt+' : '') + (e.shiftKey ? 'shift+' : '') + (e.key || '').toLowerCase();
        setTimeout(function(){
          try { window.webkit.messageHandlers.aircKeys.postMessage({combo: combo, prevented: e.defaultPrevented}); } catch (x) {}
        }, 0);
      }, true);
    })();
    """

    /// Reports whether any audible media plays, so the sidebar can show the speaker (SB-44).
    static let audioScript = """
    (function(){
      if (window.__aircAudio) return; window.__aircAudio = true;
      function report(){
        var playing = Array.prototype.some.call(document.querySelectorAll('audio,video'), function(m){
          return !m.paused && !m.ended && !m.muted && m.volume > 0 && m.readyState > 2; });
        try { window.webkit.messageHandlers.aircAudio.postMessage(playing); } catch (e) {}
      }
      ['play','playing','pause','ended','volumechange','emptied'].forEach(function(e){
        document.addEventListener(e, report, true); });
    })();
    """
}

/// Routes script messages to the tab whose web view sent them.
final class ScriptRouter: NSObject, WKScriptMessageHandler {
    private let tabs = NSMapTable<WKWebView, WebKitTab>.weakToWeakObjects()

    func register(_ tab: WebKitTab) { tabs.setObject(tab, forKey: tab.webView) }
    func tab(for webView: WKWebView) -> WebKitTab? { tabs.object(forKey: webView) }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView, let tab = tabs.object(forKey: wv) else { return }
        if message.name == "aircAudio", let playing = message.body as? Bool {
            tab.setAudible(playing)
        }
        if message.name == "aircKeys", let body = message.body as? [String: Any], let prevented = body["prevented"] as? Bool {
            tab.delegate?.tab(tab, didReceiveShortcut: body["combo"] as? String ?? "", pageUsedIt: prevented)
        }
    }
}

final class WebKitWindow: EngineWindow {
    let window: NSWindow
    let hostView: NSView
    weak var delegate: EngineWindowDelegate?
    var activeProfile: EngineProfile?
    private(set) var tabs: [WebKitTab] = []
    private weak var shown: WebKitTab?

    convenience init(contentRect: NSRect) {
        self.init(window: NSWindow(contentRect: contentRect,
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false))
    }

    /// Around a window the app made (the call window's panel).
    init(window: NSWindow) {
        self.window = window
        window.isReleasedWhenClosed = false
        hostView = PageHostView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
        hostView.wantsLayer = true
        hostView.autoresizesSubviews = true
    }

    func prepareProfile(_ profile: EngineProfile) {}

    func openTab(url: URL?, profile: EngineProfile, foreground: Bool) -> EngineTab {
        let p = profile as! WebKitProfile
        let tab = WebKitTab(configuration: p.makeConfiguration(), profile: p, window: self)
        tabs.append(tab)
        if let url { tab.load(url) }
        if foreground { activateTab(tab) }
        return tab
    }

    /// A tab WebKit created for a popup or target=_blank link.
    func adopt(configuration: WKWebViewConfiguration, opener: WebKitTab, disposition: TabDisposition) -> WKWebView {
        let tab = WebKitTab(configuration: configuration, profile: opener.webKitProfile, window: self)
        tabs.append(tab)
        delegate?.engineWindow(self, didInsertTab: tab, opener: opener, disposition: disposition)
        return tab.webView
    }

    /// A tab created by us on the page's behalf (⌘-click), announced like a WebKit-created one.
    func adoptExisting(_ tab: WebKitTab, opener: WebKitTab, disposition: TabDisposition) {
        tabs.append(tab)
        delegate?.engineWindow(self, didInsertTab: tab, opener: opener, disposition: disposition)
    }

    /// Recently shown pages stay in the window, hidden: showing one again is a visibility flip instead of re-hosting
    /// a web view (the bulk of a Space switch's frame). Older ones are taken out.
    private var attached: [WebKitTab] = []
    static let keepAttached = 6

    /// SV-1: the tabs shown in a split's panes (each web view in its pane's host view), in pane order.
    private var paneTabs: [WebKitTab] = []

    func presentPanes(_ panes: [(tab: EngineTab, host: NSView)], focused: EngineTab) throws {
        let tabs = panes.compactMap { $0.tab as? WebKitTab }
        guard (1...4).contains(panes.count), tabs.count == panes.count,
              Set(tabs.map(ObjectIdentifier.init)).count == panes.count,
              Set(panes.map { ObjectIdentifier($0.host) }).count == panes.count,
              tabs.allSatisfy({ $0.window === self && !$0.isClosed }),
              panes.allSatisfy({ $0.host.window === window }), tabs.contains(where: { $0 === focused }) else {
            throw EngineHostingError.rejected("invalidPanes")
        }
        shown?.webView.isHidden = true
        shown = nil
        for old in paneTabs where !tabs.contains(where: { $0 === old }) { old.webView.removeFromSuperview() }
        for (t, pane) in zip(tabs, panes) {
            attached.removeAll { $0 === t }
            if t.webView.superview !== pane.host {
                t.webView.frame = pane.host.bounds
                t.webView.autoresizingMask = [.width, .height]
                pane.host.addSubview(t.webView)
            }
            t.webView.isHidden = false
        }
        paneTabs = tabs
        focusPane(focused)
    }

    func focusPane(_ tab: EngineTab) {
        guard let t = tab as? WebKitTab, paneTabs.contains(where: { $0 === t }) else { return }
        t.focus()
    }

    /// Back to one page: the panes' web views leave their pane hosts.
    private func leavePanes(except keep: WebKitTab? = nil) {
        for t in paneTabs where t !== keep { t.webView.removeFromSuperview(); t.webView.isHidden = false }
        paneTabs = []
    }

    func activateTab(_ tab: EngineTab) {
        guard let t = tab as? WebKitTab else { return }
        if !paneTabs.isEmpty { leavePanes(except: t) }
        guard shown !== t || t.webView.superview !== hostView else { return }
        shown?.webView.isHidden = true
        if t.webView.superview !== hostView {
            t.webView.frame = hostView.bounds
            t.webView.autoresizingMask = [.width, .height]
            hostView.addSubview(t.webView)
        }
        t.webView.isHidden = false
        attached.removeAll { $0 === t }
        attached.append(t)
        while attached.count > Self.keepAttached {
            let old = attached.removeFirst()
            old.webView.removeFromSuperview()
            old.webView.isHidden = false
        }
        shown = t
    }

    func deactivateAll() {
        shown?.webView.isHidden = true
        shown = nil
        leavePanes()
    }

    func tabs(for profile: EngineProfile) -> [EngineTab] {
        tabs.filter { $0.profile === profile }
    }

    func remove(_ tab: WebKitTab) {
        if shown === tab { deactivateAll() }
        paneTabs.removeAll { $0 === tab }
        attached.removeAll { $0 === tab }
        tabs.removeAll { $0 === tab }
    }

    /// The same live page into this window (Little Arc's Open in, the call window): its web view changes host, and its
    /// scripts, media and calls go on. Into `hostView` it is the shown page.
    func moveTab(_ tab: EngineTab, profile: EngineProfile, to host: NSView) throws {
        guard let t = tab as? WebKitTab, !t.isClosed else { throw EngineHostingError.rejected("closedTab") }
        guard t.profile === profile else { throw EngineHostingError.rejected("profileMismatch") }
        guard host.window === window, host !== t.webView, !host.isDescendant(of: t.webView) else {
            throw EngineHostingError.rejected("invalidHost")
        }
        t.window?.remove(t)
        t.window = self
        tabs.append(t)
        if host === hostView { return activateTab(t) }
        t.webView.frame = host.bounds
        t.webView.autoresizingMask = [.width, .height]
        host.addSubview(t.webView)
        t.webView.isHidden = false
    }
}

final class WebKitTab: NSObject, EngineTab, WKNavigationDelegate, WKUIDelegate {
    private static var nextID = 1
    let tabID: Int
    let webView: WKWebView
    let webKitProfile: WebKitProfile
    weak var window: WebKitWindow?
    weak var delegate: EngineTabDelegate?
    private var observations: [NSKeyValueObservation] = []

    private(set) var favicon: NSImage?
    private(set) var faviconURL: URL?
    private(set) var isAudible = false
    private(set) var isClosed = false

    init(configuration: WKWebViewConfiguration, profile: WebKitProfile, window: WebKitWindow) {
        tabID = Self.nextID
        Self.nextID += 1
        webKitProfile = profile
        self.window = window
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        profile.router.register(self)
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self.map { $0.delegate?.tabDidChangeTitle($0) } },
            webView.observe(\.url) { [weak self] _, _ in self.map { $0.delegate?.tabDidChangeURL($0) } },
            webView.observe(\.isLoading) { [weak self] _, _ in self.map { $0.delegate?.tabDidChangeLoading($0) } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self.map { $0.delegate?.tabDidChangeLoading($0) } },
            webView.observe(\.canGoBack) { [weak self] _, _ in self.map { $0.delegate?.tabDidChangeNavigationState($0) } },
            webView.observe(\.canGoForward) { [weak self] _, _ in self.map { $0.delegate?.tabDidChangeNavigationState($0) } },
            webView.observe(\.themeColor) { [weak self] _, _ in self.map { $0.delegate?.tabDidChangeThemeColor($0) } },
        ]
    }

    var view: NSView { webView }
    var profile: EngineProfile { webKitProfile }
    var url: URL? { webView.url }
    var title: String { webView.title ?? "" }
    var isLoading: Bool { webView.isLoading }
    var progress: Double { webView.estimatedProgress }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var themeColor: NSColor? { webView.themeColor }

    var isMuted = false {
        didSet {
            webView.evaluateJavaScript(
                "document.querySelectorAll('audio,video').forEach(function(m){m.muted=\(isMuted)})")
        }
    }

    func setAudible(_ audible: Bool) {
        guard audible != isAudible else { return }
        isAudible = audible
        delegate?.tabDidChangeAudio(self)
    }

    func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    func focus() { webView.window?.makeFirstResponder(webView) }

    func evaluate(_ script: String, completion: ((Any?) -> Void)?) {
        webView.evaluateJavaScript(script) { result, _ in completion?(result) }
    }

    func snapshot(completion: @escaping (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        webView.takeSnapshot(with: config) { image, _ in completion(image) }
    }

    func discard() -> Bool { false }

    // MARK: Page commands (CB-2)

    func reloadIgnoringCache() { webView.reloadFromOrigin() }
    var history: (back: [EngineHistoryEntry], forward: [EngineHistoryEntry]) {
        let list = webView.backForwardList
        let back = list.backList.reversed().enumerated().map { i, item in
            EngineHistoryEntry(offset: -(i + 1), url: item.url.absoluteString, title: item.title ?? "")
        }
        let forward = list.forwardList.enumerated().map { i, item in
            EngineHistoryEntry(offset: i + 1, url: item.url.absoluteString, title: item.title ?? "")
        }
        return (back, forward)
    }
    func go(offset: Int) { if let item = webView.backForwardList.item(at: offset) { webView.go(to: item) } }

    /// Chrome's zoom levels.
    private static let zoomLevels: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    func zoom(step: Int) {
        guard step != 0 else { webView.pageZoom = 1; return }
        let levels = Self.zoomLevels
        let now = Double(webView.pageZoom)
        let next = step > 0 ? levels.first { $0 > now + 0.001 } : levels.last { $0 < now - 0.001 }
        if let next { webView.pageZoom = CGFloat(next) }
    }

    var zoomFactor: Double { Double(webView.pageZoom) }

    /// WebKit opens its inspector only from the page's context menu (Inspect Element); there's no public call.
    func showDevTools(console: Bool) -> Bool { false }

    func printPage(from window: NSWindow) -> Bool {
        let op = webView.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = webView.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        return true
    }

    func find(_ text: String, forward: Bool, completion: @escaping (Bool, Int?) -> Void) {
        guard !text.isEmpty else { return completion(false, nil) }
        let c = WKFindConfiguration()
        c.backwards = !forward
        c.wraps = true
        webView.find(text, configuration: c) { [weak self] result in
            // WKWebView doesn't count matches; the find bar shows how many the page's text has (case-insensitive).
            guard let self, result.matchFound,
                  let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let quoted = String(data: data, encoding: .utf8) else { return completion(result.matchFound, nil) }
            let js = "(function(t){t=t.toLowerCase();var s=((document.body&&document.body.innerText)||'').toLowerCase();"
                + "var n=0,i=0;while((i=s.indexOf(t,i))>=0){n++;i+=t.length;}return n;})(\(quoted)[0])"
            self.webView.evaluateJavaScript(js) { v, _ in completion(true, (v as? NSNumber)?.intValue) }
        }
    }

    func stopFinding() { webView.evaluateJavaScript("window.getSelection().removeAllRanges()") }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        window?.remove(self)
    }

    // MARK: Favicons

    private static let faviconScript = """
    (function(){
      var best = null, bestScore = -1;
      document.querySelectorAll('link[rel]').forEach(function(l){
        var rel = (l.getAttribute('rel') || '').toLowerCase();
        if (rel.indexOf('icon') < 0) return;
        var sizes = l.getAttribute('sizes') || '', type = l.getAttribute('type') || '';
        var m = sizes.match(/(\\d+)x(\\d+)/), px = m ? parseInt(m[1]) : 0, s;
        if (px >= 32 && px <= 96) s = 600 + px; else if (px > 96) s = 500 - px / 100;
        else if (type.indexOf('svg') >= 0 || /\\.svg(\\?|$)/.test(l.href)) s = 450;
        else if (px > 0) s = 300 + px; else s = 350;
        if (rel.indexOf('apple-touch') >= 0) s -= 100;
        if (s > bestScore) { bestScore = s; best = l.href; }
      });
      return best || (location.origin + '/favicon.ico');
    })()
    """

    private func refreshFavicon() {
        guard let pageURL = webView.url, pageURL.scheme?.hasPrefix("http") == true else { return }
        webView.evaluateJavaScript(Self.faviconScript) { [weak self] result, _ in
            guard let self, let s = result as? String, let u = URL(string: s), u != self.faviconURL else { return }
            FaviconCache.shared.load(u) { [weak self] image in
                guard let self, let image else { return }
                self.favicon = image
                self.faviconURL = u
                self.delegate?.tabDidChangeFavicon(self)
            }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // ⌘-click opens a background tab in the same Space and profile.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command),
           let url = action.request.url, let window {
            decisionHandler(.cancel, preferences)
            let tab = WebKitTab(configuration: webKitProfile.makeConfiguration(), profile: webKitProfile, window: window)
            window.adoptExisting(tab, opener: self, disposition: action.modifierFlags.contains(.shift) ? .foreground : .background)
            tab.load(url)
            return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // An attachment downloads even when WebKit could show it (a text file, an image).
        let attachment = ((response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "")
            .lowercased().hasPrefix("attachment")
        decisionHandler(response.canShowMIMEType && !(attachment && response.isForMainFrame) ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        webKitProfile.library.track(download, from: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        webKitProfile.library.track(download, from: self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshFavicon()
        delegate?.tabDidChangeLoading(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        delegate?.tabDidChangeURL(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let window else { return nil }
        let isPopup = windowFeatures.width != nil || windowFeatures.height != nil
        let disposition: TabDisposition = isPopup ? .popup
            : action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift) ? .background : .foreground
        return window.adopt(configuration: configuration, opener: self, disposition: disposition)
    }

    func webViewDidClose(_ webView: WKWebView) {
        window.map { $0.delegate?.engineWindow($0, tabRequestedClose: self) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let w = webView.window {
            alert.beginSheetModal(for: w) { _ in completionHandler() }
        } else {
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let w = webView.window {
            alert.beginSheetModal(for: w) { completionHandler($0 == .alertFirstButtonReturn) }
        } else {
            completionHandler(false)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        if let w = webView.window {
            panel.beginSheetModal(for: w) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(nil)
        }
    }
}

