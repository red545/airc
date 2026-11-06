// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit
import UniformTypeIdentifiers
import WebKit

// The dev engine's downloads and media sessions, with the same contract as Chromium's (engine/PASS13.md), so the UI is
// built and checked here first.
//
// - Downloads are WKDownloads. A file is written under a hidden partial name next to where it goes and renamed when
//   it's done, so nothing half-written (or not yet kept) sits under its real name. Pause cancels with resume data and
//   resume continues from it, as Safari does; a retry without resume data downloads again under a new id. A risky file
//   type (an app, an installer, a script) waits for Keep or Discard. History lasts the session (WebKit keeps none).
// - Media Session is read by a page script that wraps navigator.mediaSession (metadata, playback state, action
//   handlers, setMicrophoneActive / setCameraActive) and getUserMedia's tracks, and posts each change; actions call
//   the page's own handlers. Nothing polls.

extension WebKitEngine: EngineDownloads, EngineMedia, EngineCallHosting {
    var downloadsAvailable: Bool { true }
    var asksBeforeClosingWithDownloads: Bool { false }
    var mediaAvailable: Bool { true }

    func downloadItems(in profile: EngineProfile) -> [EngineDownload] { (profile as? WebKitProfile)?.library.rows ?? [] }

    func observeDownloadItems(in profile: EngineProfile, _ handler: ((EngineDownload) -> Void)?) {
        (profile as? WebKitProfile)?.library.observeDownloads(handler)
    }

    @discardableResult
    func performDownloadAction(_ action: EngineDownloadAction, id: String, in profile: EngineProfile) -> Bool {
        (profile as? WebKitProfile)?.library.perform(action, id: id) ?? false
    }

    func downloadedFile(_ id: String, in profile: EngineProfile) -> URL? { (profile as? WebKitProfile)?.library.file(id) }

    var downloadsCloseConfirmation: ((Int, @escaping (Bool) -> Void) -> Void)? {
        get { WebKitLibrary.closeConfirmation }
        set { WebKitLibrary.closeConfirmation = newValue }
    }

    func observeMediaTabs(in profile: EngineProfile, _ handler: (([EngineTab]) -> Void)?) {
        (profile as? WebKitProfile)?.library.observeMediaTabs(handler)
    }

    func mediaSession(of tab: EngineTab) -> EngineMediaSession {
        guard let t = tab as? WebKitTab else { return EngineMediaSession() }
        return t.webKitProfile.library.session(of: t)
    }

    func observeMediaSession(of tab: EngineTab, _ handler: ((EngineMediaSession) -> Void)?) {
        guard let t = tab as? WebKitTab else { return }
        t.webKitProfile.library.observeSession(of: t, handler)
    }

    @discardableResult
    func performMediaAction(_ action: String, value: Double, in tab: EngineTab) -> Bool {
        guard let t = tab as? WebKitTab, !t.isClosed else { return false }
        let session = t.webKitProfile.library.session(of: t)
        guard session.actions.contains(action) || (["play", "pause"].contains(action) && session.playback != .none) else { return false }
        let data = try! JSONSerialization.data(withJSONObject: [action])
        let arg = String(data: data, encoding: .utf8)!
        // WebKit runs this as the person's gesture, so play() is allowed.
        t.webView.evaluateJavaScript("window.__aircMedia && window.__aircMedia.perform(\(arg)[0], \(value.isFinite ? value : 0))")
        return true
    }

    func makeWindow(hosting window: NSWindow) -> EngineWindow { WebKitWindow(window: window) }
}

final class WebKitLibrary: NSObject, WKDownloadDelegate, WKScriptMessageHandler {
    private weak var profile: WebKitProfile?

    init(profile: WebKitProfile) {
        self.profile = profile
    }

    // MARK: Downloads

    /// Scripted runs download into their scratch folder, never ~/Downloads.
    static var directoryOverride: URL?
    /// Opening a finished file (scripted runs record it instead).
    static var opener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static var closeConfirmation: ((Int, @escaping (Bool) -> Void) -> Void)?
    var directory: URL { Self.directoryOverride ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    private final class Item {
        var row: EngineDownload
        var download: WKDownload?
        weak var tab: WebKitTab?
        var resumeData: Data?
        /// Where the file goes, and the hidden name it's written under until then.
        var target: URL?
        var partial: URL?
        var finished = false
        var pausing = false
        var progress: [NSKeyValueObservation] = []
        var flushQueued = false
        init(row: EngineDownload) { self.row = row }
    }

    private var items: [Item] = []
    private var observer: ((EngineDownload) -> Void)?

    var rows: [EngineDownload] { items.map(\.row) }

    func observeDownloads(_ handler: ((EngineDownload) -> Void)?) {
        observer = handler
        items.forEach { handler?($0.row) }
    }

    private func item(_ id: String) -> Item? { items.first { $0.row.id == id } }
    private func item(_ download: WKDownload) -> Item? { items.first { $0.download === download } }

    /// A page's navigation (or our retry) became a download.
    func track(_ download: WKDownload, from tab: WebKitTab?) {
        let url = download.originalRequest?.url?.absoluteString ?? ""
        let it = Item(row: EngineDownload(id: UUID().uuidString, url: url, path: nil, fileName: URL(string: url)?.lastPathComponent ?? "",
                                          received: 0, total: nil, state: .inProgress, canResume: true, startTime: Date(),
                                          referrer: tab?.url?.absoluteString))
        items.append(it)
        attach(download, to: it, from: tab)
    }

    private func attach(_ download: WKDownload, to it: Item, from tab: WebKitTab?) {
        it.download = download
        it.tab = tab ?? it.tab
        it.pausing = false
        download.delegate = self
        // Progress comes as the bytes do; the row goes out at most ten times a second, and only while it moves.
        let progress = download.progress
        it.progress = [progress.observe(\.completedUnitCount) { [weak self, weak it] p, _ in
            let done = p.completedUnitCount, total = p.totalUnitCount
            DispatchQueue.main.async {
                guard let self, let it, it.download === download else { return }
                it.row.received = max(it.row.received, done)
                if total > 0 { it.row.total = total }
                self.flushSoon(it)
            }
        }]
        emit(it)
    }

    private func flushSoon(_ it: Item) {
        guard !it.flushQueued else { return }
        it.flushQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak it] in
            guard let self, let it else { return }
            it.flushQueued = false
            self.emit(it)
        }
    }

    private func emit(_ it: Item) { observer?(it.row) }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let it = item(download) else { return completionHandler(nil) }
        if let partial = it.partial { return completionHandler(partial) }   // a resumed download writes where it was
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = Self.unique(directory.appendingPathComponent(Self.safeName(suggestedFilename)))
        let partial = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".airc-download")
        try? fm.removeItem(at: partial)
        it.target = target
        it.partial = partial
        it.row.fileName = target.lastPathComponent
        it.row.path = target.path
        it.row.mimeType = response.mimeType
        if response.expectedContentLength > 0 { it.row.total = response.expectedContentLength }
        it.row.dangerous = Self.isRisky(target)
        it.row.canKeep = it.row.dangerous
        emit(it)
        completionHandler(partial)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let it = item(download) else { return }
        it.download = nil
        it.progress = []
        it.finished = true
        it.resumeData = nil
        if let size = it.partial.flatMap({ try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }) {
            it.row.received = size.int64Value
            it.row.total = size.int64Value
        }
        // A risky file waits for Keep or Discard, still under its hidden name.
        guard !it.row.dangerous else { return emit(it) }
        complete(it)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let it = item(download) else { return }
        it.download = nil
        it.progress = []
        // Pause cancels with resume data; that isn't a failure.
        if it.pausing { return }
        it.resumeData = resumeData
        it.row.state = .interrupted
        it.row.interruptReason = 1
        it.row.canResume = resumeData != nil
        it.row.endTime = Date()
        emit(it)
    }

    private func complete(_ it: Item) {
        guard let partial = it.partial, var target = it.target else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { target = Self.unique(target) }
        do { try fm.moveItem(at: partial, to: target) } catch {
            it.row.state = .interrupted
            it.row.interruptReason = 1
            return emit(it)
        }
        it.target = target
        it.row.path = target.path
        it.row.fileName = target.lastPathComponent
        it.row.state = .complete
        it.row.dangerous = false
        it.row.canKeep = false
        it.row.canResume = false
        it.row.paused = false
        it.row.endTime = Date()
        emit(it)
        if it.row.openWhenComplete { Self.opener(target) }
    }

    func perform(_ action: EngineDownloadAction, id: String) -> Bool {
        guard let it = item(id) else { return false }
        switch action {
        case .pause:
            guard it.row.state == .inProgress, !it.row.paused, let d = it.download, !it.finished else { return false }
            it.pausing = true
            d.cancel { [weak self, weak it] data in
                DispatchQueue.main.async {
                    guard let self, let it else { return }
                    it.download = nil
                    it.progress = []
                    it.resumeData = data
                    it.row.paused = true
                    it.row.canResume = data != nil
                    self.emit(it)
                }
            }
            return true
        case .resume:
            guard it.row.state == .inProgress, it.row.paused else { return false }
            return resume(it)
        case .cancel:
            guard it.row.state == .inProgress || it.row.state == .interrupted else { return false }
            it.pausing = true
            it.download?.cancel(nil)
            it.download = nil
            it.progress = []
            it.partial.map { try? FileManager.default.removeItem(at: $0) }
            it.resumeData = nil
            it.row.state = .cancelled
            it.row.paused = false
            it.row.dangerous = false
            it.row.canResume = false
            it.row.endTime = Date()
            emit(it)
            return true
        case .retry:
            guard it.row.state == .interrupted || it.row.state == .cancelled else { return false }
            if it.resumeData != nil, it.row.state == .interrupted { return resume(it) }
            guard let url = URL(string: it.row.url), let web = webViewForDownloads(it) else { return false }
            web.startDownload(using: URLRequest(url: url)) { [weak self] d in self?.track(d, from: it.tab) }
            return true
        case .remove:
            guard it.row.state != .inProgress else { return false }
            // Off the list; a failed download's partial file goes too (a finished file stays).
            if it.row.state != .complete { it.partial.map { try? FileManager.default.removeItem(at: $0) } }
            items.removeAll { $0 === it }
            var last = it.row
            last.removed = true
            observer?(last)
            return true
        case .keep:
            guard it.row.dangerous, it.row.canKeep else { return false }
            it.row.dangerous = false
            it.row.canKeep = false
            if it.finished { complete(it) } else { emit(it) }
            return true
        case .discard:
            guard it.row.dangerous else { return false }
            it.pausing = true
            it.download?.cancel(nil)
            it.partial.map { try? FileManager.default.removeItem(at: $0) }
            items.removeAll { $0 === it }
            var last = it.row
            last.removed = true
            last.state = .cancelled
            observer?(last)
            return true
        case .open:
            guard !it.row.dangerous else { return false }
            if it.row.state == .complete, let target = it.target {
                Self.opener(target)
                return true
            }
            guard it.row.state == .inProgress else { return false }
            it.row.openWhenComplete.toggle()
            emit(it)
            return true
        }
    }

    private func resume(_ it: Item) -> Bool {
        guard let data = it.resumeData, let web = webViewForDownloads(it) else { return false }
        it.row.paused = false
        it.row.state = .inProgress
        it.row.interruptReason = 0
        it.row.endTime = nil
        emit(it)
        web.resumeDownload(fromResumeData: data) { [weak self, weak it] d in
            guard let self, let it else { return d.cancel(nil) }
            self.attach(d, to: it, from: it.tab)
        }
        return true
    }

    /// The page's own web view, or one made for the profile once that page is gone.
    private lazy var helperWebView: WKWebView? = profile.map { WKWebView(frame: .zero, configuration: $0.makeConfiguration()) }
    private func webViewForDownloads(_ it: Item) -> WKWebView? {
        if let tab = it.tab, !tab.isClosed { return tab.webView }
        return helperWebView
    }

    func file(_ id: String) -> URL? {
        guard let it = item(id), it.row.state == .complete, !it.row.dangerous, let t = it.target,
              FileManager.default.fileExists(atPath: t.path) else { return nil }
        return t
    }

    static func safeName(_ suggested: String) -> String {
        let name = suggested.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.hasPrefix(".") ? "download" + name : name
    }

    /// "name.ext", or "name 2.ext" when that's taken (Chrome's "name (1).ext" is Windows'; this is the Mac's).
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while true {
            let u = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    /// File types that can run code when opened (the dev engine's stand-in for Chromium's download protection).
    static func isRisky(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["command", "tool", "terminal", "sh", "bash", "zsh", "csh", "ksh", "app", "pkg", "mpkg", "jar", "workflow",
            "scpt", "scptd", "applescript", "fileloc", "exe", "msi", "bat", "cmd", "scr", "dll"].contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .shellScript) || type.conforms(to: .unixExecutable) || type.conforms(to: .applicationBundle)
    }

    // MARK: Media Session

    private final class Entry {
        weak var tab: WebKitTab?
        var session: EngineMediaSession
        init(tab: WebKitTab, session: EngineMediaSession) { self.tab = tab; self.session = session }
        var live: Bool { tab.map { !$0.isClosed } ?? false }
    }
    private var sessions: [ObjectIdentifier: Entry] = [:]
    private var sessionObservers: [ObjectIdentifier: (EngineMediaSession) -> Void] = [:]
    private var tabsObserver: (([EngineTab]) -> Void)?

    func installMediaBridge() {
        guard let profile else { return }
        profile.userContent.addUserScript(WKUserScript(source: Self.mediaScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        profile.userContent.add(self, name: "aircMedia")
    }

    func session(of tab: WebKitTab) -> EngineMediaSession { sessions[ObjectIdentifier(tab)]?.session ?? EngineMediaSession() }

    func observeSession(of tab: WebKitTab, _ handler: ((EngineMediaSession) -> Void)?) {
        let key = ObjectIdentifier(tab)
        sessionObservers[key] = handler
        handler?(session(of: tab))
    }

    func observeMediaTabs(_ handler: (([EngineTab]) -> Void)?) {
        tabsObserver = handler
        handler?(mediaTabs)
    }

    private var mediaTabs: [EngineTab] {
        sessions.values.compactMap { $0.live && $0.session.isPresent ? $0.tab : nil }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "aircMedia", let tab = message.webView?.navigationDelegate as? WebKitTab,
              let body = message.body as? [String: Any] else { return }
        let key = ObjectIdentifier(tab)
        let before = sessions[key]?.session ?? EngineMediaSession()
        let after = EngineMediaSession(body)
        sessions = sessions.filter { $0.value.live }
        sessions[key] = Entry(tab: tab, session: after)
        if after != before { sessionObservers[key]?(after) }
        if after.isPresent != before.isPresent { tabsObserver?(mediaTabs) }
    }

    /// Posts {playbackState, title, artist, album, artwork, actions, microphoneActive, cameraActive, capture} on every
    /// change, once per microtask; a new document starts with an empty state.
    static let mediaScript = """
    (function(){
      if (window.__aircMedia || window.top !== window) return;
      var ms = navigator.mediaSession, handlers = {}, said = {mic: null, cam: null}, pbs = null, streams = [], queued = false;
      function post(){ if (queued) return; queued = true; Promise.resolve().then(function(){ queued = false; send(); }); }
      function els(){ return Array.prototype.slice.call(document.querySelectorAll('audio,video')); }
      function live(kind){ return streams.some(function(s){ return s.getTracks().some(function(t){ return t.kind === kind && t.readyState === 'live'; }); }); }
      function send(){
        var md = ms && ms.metadata, list = els();
        // A muted element (an autoplaying ad, a call's own tiles) isn't something playing.
        list = list.filter(function(m){ return !m.muted && m.volume > 0; });
        var playing = list.some(function(m){ return !m.paused && !m.ended && m.readyState > 2; });
        var started = list.some(function(m){ return (m.currentTime > 0 || !m.paused) && !m.ended; });
        var state = pbs && pbs !== 'none' ? pbs : (playing ? 'playing' : (started ? 'paused' : 'none'));
        var art = md && md.artwork ? Array.prototype.map.call(md.artwork, function(a){ try { return new URL(a.src, location.href).href; } catch (e) { return a.src; } }) : [];
        var acts = Object.keys(handlers);
        if (state !== 'none') { ['play','pause'].forEach(function(a){ if (acts.indexOf(a) < 0) acts.push(a); }); }
        try { window.webkit.messageHandlers.aircMedia.postMessage({
          playbackState: state, active: state === 'playing', title: md ? md.title || '' : '', artist: md ? md.artist || '' : '',
          album: md ? md.album || '' : '', artwork: art, actions: acts, microphoneActive: said.mic, cameraActive: said.cam,
          capture: {microphone: live('audio'), camera: live('video'), screen: false, tab: false}}); } catch (e) {}
      }
      window.__aircMedia = {perform: function(a, v){
        var h = handlers[a];
        if (h) { try { h({action: a, seekTime: v}); } catch (e) {} return true; }
        var list = els(), m = list.filter(function(x){ return !x.paused; })[0] || list[0];
        if (!m) return false;
        if (a === 'play') { m.play(); return true; }
        if (a === 'pause') { m.pause(); return true; }
        return false;
      }};
      if (!ms) {
        // A web view without the API: a stand-in, so a page that uses it still runs and still reports.
        if (!window.MediaMetadata) window.MediaMetadata = function(o){ o = o || {}; this.title = o.title || ''; this.artist = o.artist || '';
          this.album = o.album || ''; this.artwork = o.artwork || []; };
        var held = {metadata: null, playbackState: 'none'};
        ms = {setActionHandler: function(){}, setPositionState: function(){}};
        ['metadata', 'playbackState'].forEach(function(k){ Object.defineProperty(ms, k, {configurable: true,
          get: function(){ return held[k]; }, set: function(v){ held[k] = v; }}); });
        try { Object.defineProperty(navigator, 'mediaSession', {configurable: true, value: ms}); } catch (e) {}
      }
      if (ms) {
        var proto = Object.getPrototypeOf(ms);
        ['metadata', 'playbackState'].forEach(function(k){
          var d = Object.getOwnPropertyDescriptor(ms, k) || Object.getOwnPropertyDescriptor(proto, k);
          if (!d || !d.set) return;
          Object.defineProperty(ms, k, {configurable: true, get: function(){ return d.get.call(ms); },
            set: function(v){ try { d.set.call(ms, v); } catch (e) {} if (k === 'playbackState') pbs = v; post(); }});
        });
        var set = ms.setActionHandler ? ms.setActionHandler.bind(ms) : null;
        ms.setActionHandler = function(a, h){ try { set && set(a, h); } catch (e) {} if (h) handlers[a] = h; else delete handlers[a]; post(); };
        var mic = ms.setMicrophoneActive, cam = ms.setCameraActive;
        ms.setMicrophoneActive = function(v){ said.mic = !!v; post(); try { return mic && mic.call(ms, v); } catch (e) {} };
        ms.setCameraActive = function(v){ said.cam = !!v; post(); try { return cam && cam.call(ms, v); } catch (e) {} };
      }
      var md = navigator.mediaDevices, gum = md && md.getUserMedia ? md.getUserMedia.bind(md) : null;
      if (gum) md.getUserMedia = function(c){ return gum(c).then(function(s){
        streams.push(s); s.getTracks().forEach(function(t){ t.addEventListener('ended', post); var stop = t.stop.bind(t); t.stop = function(){ stop(); post(); }; });
        post(); return s; }); };
      ['play','playing','pause','ended','emptied','loadeddata'].forEach(function(e){ document.addEventListener(e, post, true); });
      try { window.webkit.messageHandlers.aircMedia.postMessage({playbackState: 'none'}); } catch (e) {}
    })();
    """
}
