// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import WebKit
#if canImport(AircCore)
import AircCore
#endif

// Live Captures (parity N03, docs/user/easels.md; the model is AircKit's EaselLive.swift). A Capture block with a live
// source is taken again from its page:
//
// - **Refresh** (the block's menu, ⌘R for all of an Easel's) and **Live** (by itself when the Easel opens and every so
//   often while it's shown, if older than EaselLivePolicy.staleAfter) load the page offscreen, in the profile it was
//   captured in (so it's signed in as it was), laid out at the captured viewport, scrolled as it was, and picture the
//   whole viewport through the engine (WebKit's takeSnapshot, Chromium's DevTools screenshot of its compositor frame).
//   The region is cut from it by its CSS pixels, so it holds across zoom and reload. The new picture replaces the old
//   one without an undo step; signed out, offline or broken, the old picture stays and the block says why.
// - **Interact** (double-click a live Capture): the real page goes over the block, at its size, scrolled to the region,
//   in the window's own engine window (the way a split's pane is shown). Esc or a click outside ends it and pictures
//   the region again.
//
// The offscreen page never plays media (muted, no autoplay, playback suspended), never asks for a permission (camera,
// microphone, location, notifications, devices are refused in the page before its scripts run, and the engine answers
// any request from a page no window shows with dismiss), shows no dialogs, opens no windows, downloads nothing, and is
// closed as soon as its picture is taken (or its 20 s are up, or the refresh is cancelled). Private windows have no
// Easels and their pages have no Airc profile, so a live source can't point at one.

/// Why a refresh didn't produce a picture (mapped to the block's state).
enum LivePageFailure: Error {
    case cancelled
    case signedOut
    case offline
    case failed(String)
}

/// What a loader brings back: the whole viewport's picture, and where the page was when it was taken.
struct LivePageShot {
    let image: CGImage
    let metrics: EaselLiveGeometry.PageMetrics
}

/// One offscreen page for one refresh.
protocol LivePageLoader: AnyObject {
    func start(_ s: EaselLiveSource, _ done: @escaping (Result<LivePageShot, LivePageFailure>) -> Void)
    /// Stops at once (closing the page); `done` isn't called after.
    func cancel()
}

// MARK: - The page guards

enum LivePageGuards {
    /// Runs in the page's own world before its scripts, in every frame: nothing that would ask for a permission, play
    /// sound, open a window, show a dialog or leave a question behind.
    static let script = """
    (function(){
      if (window.__aircLiveGuard) return; window.__aircLiveGuard = true;
      var deny = function(){ return Promise.reject(new DOMException('Not allowed in a live capture', 'NotAllowedError')); };
      function set(o, k, v){ try { Object.defineProperty(o, k, {value: v, configurable: true, writable: true}); } catch (e) { try { o[k] = v; } catch (x) {} } }
      try { var md = navigator.mediaDevices; if (md) { set(md, 'getUserMedia', deny); set(md, 'getDisplayMedia', deny); set(md, 'enumerateDevices', function(){ return Promise.resolve([]); }); } } catch (e) {}
      ['getUserMedia', 'webkitGetUserMedia', 'mozGetUserMedia', 'requestMIDIAccess', 'requestMediaKeySystemAccess'].forEach(function(k){ if (k in navigator) set(navigator, k, deny); });
      try { if (navigator.geolocation) { var no = function(s, e){ if (e) setTimeout(function(){ e({code: 1, message: 'denied'}); }, 0); return 0; }; set(navigator.geolocation, 'getCurrentPosition', no); set(navigator.geolocation, 'watchPosition', no); } } catch (e) {}
      try { if (window.Notification) { set(Notification, 'requestPermission', function(){ return Promise.resolve('denied'); }); } } catch (e) {}
      ['usb', 'hid', 'serial', 'bluetooth'].forEach(function(k){ try { var d = navigator[k]; if (d) { set(d, 'requestDevice', deny); set(d, 'requestPort', deny); } } catch (e) {} });
      try { if (navigator.credentials) { set(navigator.credentials, 'get', deny); set(navigator.credentials, 'create', deny); } } catch (e) {}
      try { if (navigator.clipboard) { set(navigator.clipboard, 'readText', deny); set(navigator.clipboard, 'read', deny); } } catch (e) {}
      try { if (window.PushManager) set(PushManager.prototype, 'subscribe', deny); } catch (e) {}
      try { if (window.IdleDetector) set(IdleDetector, 'requestPermission', function(){ return Promise.resolve('denied'); }); } catch (e) {}
      try { set(window, 'showDirectoryPicker', deny); set(window, 'showOpenFilePicker', deny); set(window, 'showSaveFilePicker', deny); } catch (e) {}
      set(window, 'open', function(){ return null; });
      set(window, 'alert', function(){}); set(window, 'confirm', function(){ return false; }); set(window, 'prompt', function(){ return null; }); set(window, 'print', function(){});
      try { set(HTMLMediaElement.prototype, 'play', function(){ try { this.muted = true; this.pause(); } catch (e) {} return deny(); }); } catch (e) {}
      document.addEventListener('play', function(e){ try { e.target.muted = true; e.target.pause(); } catch (x) {} }, true);
      try { set(HTMLElement.prototype, 'requestFullscreen', deny); set(Element.prototype, 'requestPointerLock', deny); } catch (e) {}
      window.addEventListener('beforeunload', function(e){ e.stopImmediatePropagation(); }, true);
    })();
    """

    /// The answer both engines read: where the page ended up and whether it failed.
    static let statusScript = """
    JSON.stringify({href: location.href, online: navigator.onLine,
      status: ((performance.getEntriesByType && performance.getEntriesByType('navigation')[0]) || {}).responseStatus || 0,
      error: location.protocol === 'chrome-error:' ? (((document.body && document.body.innerText) || '').match(/ERR_[A-Z_]+/) || ['ERR_FAILED'])[0] : ''})
    """

    #if AIRC_TESTING
    /// Scripted checks: run in the offscreen page just before its picture (the guards' effect, media state).
    static var testProbe: (script: String, result: (Any?) -> Void)?
    #endif

    static func scrollScript(_ x: Double, _ y: Double) -> String { "window.scrollTo(\(Int(x)), \(Int(y))); true" }

    static let offlineErrors: Set<String> = ["ERR_INTERNET_DISCONNECTED", "ERR_NETWORK_CHANGED", "ERR_NAME_NOT_RESOLVED", "ERR_ADDRESS_UNREACHABLE",
                                             "ERR_NETWORK_ACCESS_DENIED", "ERR_PROXY_CONNECTION_FAILED"]

    /// The page's state as a failure, or nil when it's the page.
    static func failure(statusJSON: Any?, source: EaselLiveSource, httpStatus: Int?) -> LivePageFailure? {
        var o: [String: Any] = [:]
        if let s = statusJSON as? String, let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { o = j }
        let error = o["error"] as? String ?? ""
        if !error.isEmpty {
            if offlineErrors.contains(error) || o["online"] as? Bool == false { return .offline }
            return .failed("Couldn't load the page (\(error))")
        }
        let status = httpStatus ?? (o["status"] as? NSNumber)?.intValue ?? 0
        if EaselLiveGeometry.looksSignedOut(captured: source.url, landed: o["href"] as? String, httpStatus: status) { return .signedOut }
        if status >= 400 { return .failed(status == 404 ? "Page not found (404)" : "The page answered \(status)") }
        return nil
    }
}

// MARK: - The offscreen window

/// The window a refresh's page lives in: never key or main, no mouse, not in the Window menu, ⌘` or Mission Control,
/// off every screen and behind everything, so nobody ever sees it.
final class LiveCaptureWindow: NSWindow {
    /// Done with: nothing may order it in again (the engine fronts its window as it closes it).
    var retired = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKeyAndOrderFront(_ sender: Any?) { if !retired { orderBack(sender) } }
    override func makeKey() {}
    override func orderFrontRegardless() {}
    override func orderFront(_ sender: Any?) { if !retired { orderBack(sender) } }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if retired, place != .out { return }
        // Never in front of anything: only behind (or out).
        super.order(place == .above ? .below : place, relativeTo: place == .above ? 0 : otherWin)
    }

    /// Out of the window list for good.
    func retire() {
        orderOut(nil)
        retired = true
    }
    override func sendEvent(_ event: NSEvent) {
        if [.keyDown, .keyUp, .flagsChanged].contains(event.type) { return }
        super.sendEvent(event)
    }

    /// Left of every screen, by its own width and more.
    static func offscreenOrigin(_ size: CGSize) -> NSPoint {
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        return NSPoint(x: union.minX - size.width - 6000, y: union.minY)
    }

    static func make(size: CGSize) -> LiveCaptureWindow {
        let frame = NSRect(origin: offscreenOrigin(size), size: size)
        let w = LiveCaptureWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isExcludedFromWindowsMenu = true
        w.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false
        w.animationBehavior = .none
        w.isRestorable = false
        w.tabbingMode = .disallowed
        w.backgroundColor = .white
        w.title = "Airc live capture"
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.autoresizesSubviews = true
        w.contentView = content
        return w
    }

    /// Ordered in behind everything (so its pages are live), then off screen.
    func park() {
        orderBack(nil)
        setFrameOrigin(Self.offscreenOrigin(frame.size))
    }

    func resize(to size: CGSize) {
        setFrame(NSRect(origin: Self.offscreenOrigin(size), size: size), display: false)
    }
}

/// The viewport an offscreen page is laid out at: the captured one, within what a window can be.
private func liveViewport(_ s: EaselLiveSource, zoom: Double = 1) -> CGSize {
    CGSize(width: min(4096, max(200, s.viewportWidth * zoom)), height: min(4096, max(150, s.viewportHeight * zoom)))
}

// MARK: - WebKit

/// The WebKit engine's offscreen page: a web view of its own on the profile's website data (cookies, storage: signed in
/// as the profile is), with none of the app's page scripts, only the guards, and no autoplay.
final class WebKitLivePageLoader: NSObject, LivePageLoader, WKNavigationDelegate, WKUIDelegate {
    private let dataStore: WKWebsiteDataStore
    private var window: LiveCaptureWindow?
    private var webView: WKWebView?
    private var done: ((Result<LivePageShot, LivePageFailure>) -> Void)?
    private var source: EaselLiveSource?
    private var httpStatus: Int?
    private var finished = false
    private var navigationEnded = false

    init(dataStore: WKWebsiteDataStore) { self.dataStore = dataStore }

    func start(_ s: EaselLiveSource, _ done: @escaping (Result<LivePageShot, LivePageFailure>) -> Void) {
        guard let url = URL(string: s.url) else { return done(.failure(.failed("Not a page address"))) }
        self.done = done
        source = s
        let size = liveViewport(s)
        let w = LiveCaptureWindow.make(size: size)
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: LivePageGuards.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        c.userContentController = content
        c.mediaTypesRequiringUserActionForPlayback = .all
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.preferences.isElementFullscreenEnabled = false
        c.applicationNameForUserAgent = WebKitProfile.safariProduct
        let v = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: c)
        v.navigationDelegate = self
        v.uiDelegate = self
        v.autoresizingMask = [.width, .height]
        v.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        // A page in a window off screen still draws (WebKit SPI, as the agent windows use; without it the snapshot of an
        // occluded page can wait for a frame that never comes, and the time-out ends it).
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if v.responds(to: sel) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(v.method(for: sel), to: SetBool.self)(v, sel, false)
        }
        w.contentView?.addSubview(v)
        w.park()
        window = w
        webView = v
        v.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: EaselLivePolicy.timeout))
    }

    private func finish(_ r: Result<LivePageShot, LivePageFailure>) {
        guard !finished else { return }
        finished = true
        let d = done
        done = nil
        tearDown()
        d?(r)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        done = nil
        tearDown()
    }

    private func tearDown() {
        if let v = webView {
            v.stopLoading()
            v.navigationDelegate = nil
            v.uiDelegate = nil
            v.pauseAllMediaPlayback(completionHandler: nil)
            v.removeFromSuperview()
        }
        webView = nil
        window?.retire()
        window?.close()
        window = nil
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only web pages (no app links, no mailto:, no files).
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let h = response.response as? HTTPURLResponse { httpStatus = h.statusCode }
        // Nothing is downloaded.
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
        if response.isForMainFrame, !response.canShowMIMEType { finish(.failure(.failed("Not a page"))) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return }   // a redirect or a new navigation
        if e.domain == "WebKitErrorDomain", e.code == 102 { return }   // frame load interrupted (a download refused)
        let offline: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed,
                                 NSURLErrorInternationalRoamingOff, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed]
        if e.domain == NSURLErrorDomain, offline.contains(e.code) { return finish(.failure(.offline)) }
        finish(.failure(.failed("Couldn't load the page")))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !navigationEnded, let s = source else { return }
        navigationEnded = true
        // Late layout, fonts and pictures settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.check(s) }
    }

    private func check(_ s: EaselLiveSource) {
        guard !finished, let v = webView else { return }
        v.evaluateJavaScript(LivePageGuards.statusScript) { [weak self] status, _ in
            guard let self, !self.finished else { return }
            if let f = LivePageGuards.failure(statusJSON: status, source: s, httpStatus: self.httpStatus) { return self.finish(.failure(f)) }
            let (x, y) = EaselLiveGeometry.scrollTarget(s)
            v.evaluateJavaScript(LivePageGuards.scrollScript(x, y)) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.picture() }
            }
        }
    }

    private func picture() {
        guard !finished, let v = webView else { return }
        #if AIRC_TESTING
        if let probe = LivePageGuards.testProbe {
            LivePageGuards.testProbe = nil
            return v.evaluateJavaScript(probe.script) { [weak self] r, _ in
                probe.result(r)
                self?.picture()
            }
        }
        #endif
        v.evaluateJavaScript(EaselLiveGeometry.PageMetrics.script) { [weak self] m, _ in
            guard let self, !self.finished else { return }
            guard let metrics = EaselLiveGeometry.PageMetrics(m) else { return self.finish(.failure(.failed("The page didn't answer"))) }
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            v.takeSnapshot(with: config) { [weak self] image, _ in
                guard let self, !self.finished else { return }
                guard let image, let cg = CaptureSession.pixels(image) else { return self.finish(.failure(.failed("The page didn't draw"))) }
                self.finish(.success(LivePageShot(image: cg, metrics: metrics)))
            }
        }
    }

    // MARK: Nothing asks anyone anything

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}

// MARK: - Chromium

#if canImport(AircCore)
/// The Chromium engine's offscreen page: a tab in an internal engine window (no extension or history sees it, a page's
/// window.focus() never brings it forward), muted, with the guards added through its DevTools session before the page
/// loads, and focus emulation so a page in a window off screen still draws. The picture is the compositor's frame
/// (`Page.captureScreenshot`).
final class ChromiumLivePageLoader: LivePageLoader {
    private let engine: ChromiumEngine
    private let profile: ChromiumProfile
    private var window: LiveCaptureWindow?
    private var engineWindow: ChromiumWindow?
    private var tab: ChromiumTab?
    private var done: ((Result<LivePageShot, LivePageFailure>) -> Void)?
    private var finished = false
    private var source: EaselLiveSource?
    private var started = Date()

    init(engine: ChromiumEngine, profile: ChromiumProfile) {
        self.engine = engine
        self.profile = profile
    }

    private func call(_ method: String, _ params: [String: Any]?, timeout: TimeInterval = 8, _ completion: @escaping ([String: Any]?, String?) -> Void) {
        guard let core = tab?.core, tab?.isClosed == false else { return completion(nil, "closed") }
        core.devToolsCall(method, params: params, timeout: timeout) { r, e in completion(r as? [String: Any], e) }
    }

    func start(_ s: EaselLiveSource, _ done: @escaping (Result<LivePageShot, LivePageFailure>) -> Void) {
        guard let url = URL(string: s.url) else { return done(.failure(.failed("Not a page address"))) }
        self.done = done
        source = s
        started = Date()
        // The captured zoom first; corrected once the page says its layout width (this site's zoom may have changed).
        let size = liveViewport(s, zoom: s.zoom)
        let w = LiveCaptureWindow.make(size: size)
        guard let ew = engine.makeWindow(hosting: w) as? ChromiumWindow else { return finish(.failure(.failed("No engine window"))) }
        ew.core.internal = true
        let host = ew.hostView
        host.frame = w.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(host)
        ew.activeProfile = profile
        ew.prepareProfile(profile)
        w.park()
        window = w
        engineWindow = ew
        guard let t = ew.openChromiumTab(url: nil, profile: profile, foreground: false) as? ChromiumTab else {
            return finish(.failure(.failed("The page couldn't open")))
        }
        tab = t
        t.isMuted = true
        ew.activateTab(t)
        t.view.frame = host.bounds
        // The DevTools session lives while a call is pending: an endless one keeps the guards and the focus emulation.
        call("Runtime.evaluate", ["expression": "new Promise(function(){})", "awaitPromise": true], timeout: 0) { _, _ in }
        call("Emulation.setFocusEmulationEnabled", ["enabled": true]) { [weak self] _, _ in
            self?.call("Page.setDownloadBehavior", ["behavior": "deny"]) { _, _ in
                self?.call("Page.addScriptToEvaluateOnNewDocument", ["source": LivePageGuards.script]) { _, _ in
                    guard let self, !self.finished else { return }
                    // Navigated through the same session: Page.navigate stays pending until the new document commits,
                    // so the session (and the guards it added) lives into that document (the endless call above ends
                    // with the old one). Then it's kept for the new one, and the guards run there once more.
                    self.call("Page.navigate", ["url": url.absoluteString], timeout: EaselLivePolicy.timeout) { [weak self] _, _ in
                        guard let self, !self.finished else { return }
                        self.call("Runtime.evaluate", ["expression": "new Promise(function(){})", "awaitPromise": true], timeout: 0) { _, _ in }
                        self.call("Emulation.setFocusEmulationEnabled", ["enabled": true]) { _, _ in }
                        self.call("Runtime.evaluate", ["expression": LivePageGuards.script]) { _, _ in }
                    }
                    self.poll()
                }
            }
        }
    }

    /// Loaded (and the address is the page's, not about:blank): settle, then check.
    private func poll() {
        guard !finished, let t = tab, let s = source else { return }
        let ready = !t.isLoading && t.url.map { $0.scheme == "http" || $0.scheme == "https" || $0.scheme == "chrome-error" } == true
            && Date().timeIntervalSince(started) > 0.5
        guard ready else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.poll() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.check(s) }
    }

    private func evaluate(_ js: String, _ done: @escaping (Any?) -> Void) {
        call("Runtime.evaluate", ["expression": js, "returnByValue": true]) { r, _ in
            done((r?["result"] as? [String: Any])?["value"])
        }
    }

    private func check(_ s: EaselLiveSource) {
        guard !finished else { return }
        evaluate(LivePageGuards.statusScript) { [weak self] status in
            guard let self, !self.finished else { return }
            if let f = LivePageGuards.failure(statusJSON: status, source: s, httpStatus: nil) { return self.finish(.failure(f)) }
            self.evaluate(EaselLiveGeometry.PageMetrics.script) { [weak self] m in
                guard let self, !self.finished, let w = self.window else { return }
                // This site's zoom now: lay the page out at the captured CSS width again.
                if let m = EaselLiveGeometry.PageMetrics(m), abs(m.innerWidth - s.viewportWidth) > 1 {
                    let z = Double(w.frame.width) / m.innerWidth
                    w.resize(to: liveViewport(s, zoom: z))
                    self.tab?.view.frame = self.engineWindow?.hostView.bounds ?? .zero
                }
                let (x, y) = EaselLiveGeometry.scrollTarget(s)
                self.evaluate(LivePageGuards.scrollScript(x, y)) { [weak self] _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.picture() }
                }
            }
        }
    }

    private func picture() {
        guard !finished else { return }
        #if AIRC_TESTING
        if let probe = LivePageGuards.testProbe {
            LivePageGuards.testProbe = nil
            return evaluate(probe.script) { [weak self] r in
                probe.result(r)
                self?.picture()
            }
        }
        #endif
        evaluate(EaselLiveGeometry.PageMetrics.script) { [weak self] m in
            guard let self, !self.finished else { return }
            guard let metrics = EaselLiveGeometry.PageMetrics(m) else { return self.finish(.failure(.failed("The page didn't answer"))) }
            self.call("Page.captureScreenshot", ["format": "png", "fromSurface": true], timeout: 10) { [weak self] r, _ in
                guard let self, !self.finished else { return }
                guard let b64 = r?["data"] as? String, let data = Data(base64Encoded: b64),
                      let src = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    return self.finish(.failure(.failed("The page didn't draw")))
                }
                self.finish(.success(LivePageShot(image: image, metrics: metrics)))
            }
        }
    }

    private func finish(_ r: Result<LivePageShot, LivePageFailure>) {
        guard !finished else { return }
        finished = true
        let d = done
        done = nil
        tearDown()
        d?(r)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        done = nil
        tearDown()
    }

    private func tearDown() {
        let t = tab, ew = engineWindow, w = window
        tab = nil
        engineWindow = nil
        window = nil
        w?.retire()
        if let t, !t.isClosed {
            // No "Leave site?" for a page nobody sees.
            t.core.devToolsCall("Runtime.evaluate", params: ["expression": "window.onbeforeunload = null; true"], timeout: 1) { _, _ in }
            t.close()
        }
        // The pages' closes go out before the window does (as an agent window's).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let ew, !ChromiumRuntime.closeWindow(ew) { return }
            w?.close()
        }
    }
}
#endif

// MARK: - Refreshing

/// Every live Capture's refreshes, app-wide: at most two at once, each at most 20 s, a block never twice at once.
final class EaselLiveCenter {
    static let shared = EaselLiveCenter()

    final class Job {
        let easelID: String
        let blockID: String
        let source: EaselLiveSource
        let manual: Bool
        weak var editor: EaselEditor?
        var loader: LivePageLoader?
        var timeout: DispatchWorkItem?
        var ended = false

        init(editor: EaselEditor, blockID: String, source: EaselLiveSource, manual: Bool) {
            self.editor = editor
            easelID = editor.easelID
            self.blockID = blockID
            self.source = source
            self.manual = manual
        }
    }

    private var waiting: [Job] = []
    private var running: [Job] = []
    private var timer: Timer?
    #if AIRC_TESTING
    /// Scripted checks: every refresh's ending (the block, and "picture", "signedOut", "offline", "failed: …",
    /// "cancelled", "unavailable").
    var onEnded: ((String, String, String) -> Void)?
    /// Pages the loaders made (the check counts that they all closed).
    private(set) var loadersMade = 0
    #endif

    private init() {}

    /// The engine and the profile host refreshes run with (any browser window's; they're the app's).
    private var environment: (BrowserEngine, ProfileHost)? {
        guard let app = NSApp.delegate as? AppDelegate, let engine = app.engine,
              let c = EaselCenter.shared.openEditors.lazy.compactMap({ $0.controller }).first else { return nil }
        return (engine, c.profiles)
    }

    func isRefreshing(_ easelID: String, _ blockID: String) -> Bool {
        (waiting + running).contains { $0.easelID == easelID && $0.blockID == blockID }
    }

    var activeCount: Int { running.count }

    /// Refreshes blocks `ids` of `editor`'s Easel (their sources as they are now). `manual`: asked for (Refresh, ⌘R),
    /// so back-off and Manual mode don't hold it back.
    func refresh(_ editor: EaselEditor, _ ids: [String], manual: Bool) {
        // Only an Easel with Live blocks needs the minute tick (MEM-6: opening any Easel used to start it for good).
        if !editor.document.liveBlocks.isEmpty || Self.baseline { startTimer() }
        for id in ids {
            guard let s = editor.document.liveSource(id), s.isValid, !isRefreshing(editor.easelID, id) else { continue }
            waiting.append(Job(editor: editor, blockID: id, source: s, manual: manual))
            editor.refreshingChanged()
        }
        pump()
    }

    /// An Easel came on screen: its Live blocks that are due.
    func shown(_ editor: EaselEditor) {
        refresh(editor, editor.document.dueLiveBlocks(now: Date()), manual: false)
    }

    /// Stops refreshes of Easel `easelID` (one block's, or all): their pages close, nothing lands.
    func cancel(easelID: String, blockID: String? = nil) {
        let match: (Job) -> Bool = { $0.easelID == easelID && (blockID == nil || $0.blockID == blockID) }
        let gone = (waiting + running).filter(match)
        waiting.removeAll(where: match)
        for j in gone { end(j, .cancelled) }
        pump()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Every minute: the Live blocks that came due on the Easels on screen (a hidden or minimised one waits).
    /// Stops once no open Easel has a Live block and nothing is waiting; the next Live Easel shown starts it again.
    private func tick() {
        for e in EaselCenter.shared.openEditors {
            guard let w = e.view.window, w.isVisible, w.occlusionState.contains(.visible), e.view.superview != nil else { continue }
            refresh(e, e.document.dueLiveBlocks(now: Date()), manual: false)
        }
        if Self.baseline { return }
        if waiting.isEmpty, running.isEmpty, !EaselCenter.shared.openEditors.contains(where: { !$0.document.liveBlocks.isEmpty }) {
            timer?.invalidate()
            timer = nil
        }
    }
    #if AIRC_TESTING
    /// MEM-6 A/B (artifacts/idletimers): the old tick, started by any Easel and never stopped, same binary.
    static let baseline = ProcessInfo.processInfo.environment["AIRC_IDLETIMERS_BASELINE"] == "1"
    #else
    static let baseline = false
    #endif
    #if AIRC_TESTING
    /// Whether the minute tick is running (checks).
    var tickRunning: Bool { timer != nil }
    #endif

    private func pump() {
        while running.count < EaselLivePolicy.concurrency, !waiting.isEmpty {
            let j = waiting.removeFirst()
            running.append(j)
            run(j)
        }
    }

    private func run(_ j: Job) {
        guard j.editor != nil, let env = environment else { return end(j, .cancelled) }
        let (engine, profiles) = env
        guard profiles.store.profile(j.source.profileID) != nil else { return end(j, .unavailable) }
        let t = DispatchWorkItem { [weak self] in
            guard let self, !j.ended else { return }
            j.loader?.cancel()
            self.end(j, .failure(.failed("The page took too long")))
        }
        j.timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + EaselLivePolicy.timeout, execute: t)
        profiles.whenLoaded(j.source.profileID, { [weak self] ep in
            guard let self, !j.ended else { return }
            guard let loader = self.loader(engine: engine, profile: ep) else { return self.end(j, .failure(.failed("This engine can't refresh it"))) }
            #if AIRC_TESTING
            self.loadersMade += 1
            #endif
            j.loader = loader
            loader.start(j.source) { [weak self] r in
                guard let self, !j.ended else { return }
                switch r {
                case .success(let shot): self.end(j, .shot(shot))
                case .failure(let f): self.end(j, .failure(f))
                }
            }
        }, failed: { [weak self] in self?.end(j, .unavailable) })
    }

    private func loader(engine: BrowserEngine, profile: EngineProfile) -> LivePageLoader? {
        #if canImport(AircCore)
        if let c = engine as? ChromiumEngine, let p = profile as? ChromiumProfile { return ChromiumLivePageLoader(engine: c, profile: p) }
        #endif
        if let p = profile as? WebKitProfile, !p.privateSession { return WebKitLivePageLoader(dataStore: p.dataStore) }
        return nil
    }

    private enum Ending {
        case shot(LivePageShot)
        case failure(LivePageFailure)
        case unavailable
        case cancelled
    }

    private func end(_ j: Job, _ e: Ending) {
        guard !j.ended else { return }
        j.ended = true
        j.timeout?.cancel()
        if case .cancelled = e { j.loader?.cancel() }
        j.loader = nil
        running.removeAll { $0 === j }
        waiting.removeAll { $0 === j }
        var label = "cancelled"
        if let editor = j.editor {
            var outcome: EaselLiveOutcome?
            switch e {
            case .shot(let shot):
                if let crop = EaselLiveGeometry.crop(j.source, pixelWidth: Double(shot.image.width), pixelHeight: Double(shot.image.height), page: shot.metrics),
                   let part = shot.image.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)),
                   let stored = EaselCenter.shared.storePicture(cgImage: part, in: j.easelID) {
                    outcome = .picture(asset: stored.asset, pixelWidth: stored.pixelWidth, pixelHeight: stored.pixelHeight)
                    label = "picture"
                } else {
                    outcome = .failed("That part of the page is gone")
                    label = "failed: gone"
                }
            case .failure(.signedOut): outcome = .signedOut; label = "signedOut"
            case .failure(.offline): outcome = .offline; label = "offline"
            case .failure(.failed(let m)): outcome = .failed(m); label = "failed: \(m)"
            case .failure(.cancelled), .cancelled: outcome = nil
            case .unavailable: outcome = .unavailable; label = "unavailable"
            }
            if let outcome { editor.applyLive(outcome, blockID: j.blockID, sourceID: j.source.id) }
            editor.refreshingChanged()
        }
        #if AIRC_TESTING
        onEnded?(j.easelID, j.blockID, label)
        #endif
        _ = label
        DispatchQueue.main.async { [weak self] in self?.pump() }
    }
}

// MARK: - Interacting

/// A live Capture made the real page for a while (double-click): over the block, at the page's size, scrolled to the
/// region, in the window's own engine window. It ends on Esc (the key monitor, App/Commands.swift), a click outside it, the Easel leaving the card, or
/// another block's double-click, and the region is pictured again as it is then.
final class EaselInteraction {
    private(set) static var current: EaselInteraction?

    let editor: EaselEditor
    let blockID: String
    let source: EaselLiveSource
    private weak var controller: WindowController?
    private let clip = FlippedClipView()
    private let host = NSView()
    private var tab: EngineTab?
    private var monitors: [Any] = []
    private var ended = false

    /// The view that cuts the page to the block.
    final class FlippedClipView: NSView {
        override var isFlipped: Bool { true }
    }

    var pageView: NSView? { tab?.view }
    var page: EngineTab? { tab }
    /// The browser window it's in (the key monitor's Esc, App/Commands.swift).
    var window: NSWindow? { clip.window }

    static func begin(_ editor: EaselEditor, blockID: String) {
        current?.end(capture: true)
        guard let c = editor.controller, let s = editor.document.liveSource(blockID), s.isValid, let url = URL(string: s.url),
              let b = editor.document.block(blockID), let ep = c.profiles.engineProfile(for: s.profileID), !c.captureIsPrivate else { return NSSound.beep() }
        let i = EaselInteraction(editor: editor, blockID: blockID, source: s, controller: c)
        current = i
        i.start(url: url, block: b, profile: ep)
    }

    private init(editor: EaselEditor, blockID: String, source: EaselLiveSource, controller: WindowController) {
        self.editor = editor
        self.blockID = blockID
        self.source = source
        self.controller = controller
    }

    private func start(url: URL, block b: EaselBlock, profile: EngineProfile) {
        guard let c = controller else { return }
        let canvas = editor.view.canvas
        // The board at the page's size: the region's CSS width at its zoom fills the block.
        let z = min(EaselMetrics.maximumZoom, max(EaselMetrics.minimumZoom, source.rect.width * source.zoom / max(1, b.frame.width)))
        canvas.center(on: b.frame.center, zoom: z)
        let r = canvas.viewRect(b.frame)
        clip.frame = canvas.convert(r, to: editor.view)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerRadius = 8
        clip.setAccessibilityIdentifier("easel.live.interaction")
        let k = source.zoom
        host.frame = NSRect(x: -(source.rect.x - source.scrollX) * k, y: -(source.rect.y - source.scrollY) * k,
                            width: source.viewportWidth * k, height: source.viewportHeight * k)
        clip.addSubview(host)
        editor.view.addSubview(clip, positioned: .above, relativeTo: canvas)
        let t = c.engineWindow.openTab(url: url, profile: profile, foreground: false)
        tab = t
        do {
            try c.engineWindow.presentPanes([(tab: t, host: host)], focused: t)
        } catch {
            return end(capture: false)
        }
        t.focus()
        scrollWhenLoaded(0)
        // A click outside ends it (Esc does too: the key monitor, App/Commands.swift, before the page sees it).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            guard let self, e.window === self.clip.window else { return e }
            if !self.clip.bounds.contains(self.clip.convert(e.locationInWindow, from: nil)) { self.end(capture: true) }
            return e
        }) { monitors.append(m) }
    }

    /// Once the page has loaded: scrolled as it was when captured, so the region sits in the block.
    private func scrollWhenLoaded(_ n: Int) {
        guard !ended, let t = tab else { return }
        if t.isLoading && n < 100 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.scrollWhenLoaded(n + 1) }
            return
        }
        t.evaluate(LivePageGuards.scrollScript(source.scrollX, source.scrollY), completion: nil)
    }

    /// Ends it: `capture` pictures the region first (as the page shows it now).
    func end(capture: Bool) {
        guard !ended else { return }
        ended = true
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if Self.current === self { Self.current = nil }
        guard capture, let t = tab, !t.isClosed else { return close() }
        let src = source, editor = editor, blockID = blockID
        // Held until it has closed (nothing else keeps it once `current` lets go).
        t.evaluate(EaselLiveGeometry.PageMetrics.script) { m in
            CaptureSession.picture(of: t) { image in
                if let image, let metrics = EaselLiveGeometry.PageMetrics(m),
                   let crop = EaselLiveGeometry.crop(src, pixelWidth: Double(image.width), pixelHeight: Double(image.height), page: metrics),
                   let part = image.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)),
                   let stored = EaselCenter.shared.storePicture(cgImage: part, in: editor.easelID) {
                    editor.applyLive(.picture(asset: stored.asset, pixelWidth: stored.pixelWidth, pixelHeight: stored.pixelHeight),
                                     blockID: blockID, sourceID: src.id)
                }
                self.close()
            }
        }
    }

    private func close() {
        if let t = tab, !t.isClosed {
            if let c = controller, c.shownEasel === editor { c.engineWindow.deactivateAll() }
            t.close()
        }
        tab = nil
        clip.removeFromSuperview()
        if editor.view.window != nil { editor.focus() }
    }
}
