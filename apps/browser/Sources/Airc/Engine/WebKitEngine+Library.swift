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
        if action == "play" { t.webView.setAllMediaPlaybackSuspended(false) }
        // WebKit runs this as the person's gesture, so play() is allowed.
        t.webView.evaluateJavaScript("window.__aircMedia && window.__aircMedia.perform(\(arg)[0], \(value.isFinite ? value : 0))", in: t.webKitProfile.library.mediaFrame(of: t), in: .page) { _ in
            // Includes media outside the DOM and subframes. Never suspend for mute: playback must advance.
            if action == "pause" { t.webView.pauseAllMediaPlayback(completionHandler: nil) }
        }
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
                                          // The page shown (committed), not the download's own address the tab was
                                          // navigating to (Tidy Downloads names files from it).
                                          referrer: (tab?.webView.backForwardList.currentItem?.url ?? tab?.url)?.absoluteString))
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
        var frames: [String: (WKFrameInfo, EngineMediaSession)] = [:]
        var selectedFrame: WKFrameInfo?
        var audibleFrames: Set<String> = []
        init(tab: WebKitTab, session: EngineMediaSession) { self.tab = tab; self.session = session }
        var live: Bool { tab.map { !$0.isClosed } ?? false }
    }
    private var sessions: [ObjectIdentifier: Entry] = [:]
    private var sessionObservers: [ObjectIdentifier: (EngineMediaSession) -> Void] = [:]
    private var tabsObserver: (([EngineTab]) -> Void)?
    private let remoteToken = UUID().uuidString

    func installMediaBridge() {
        guard let profile else { return }
        profile.userContent.addUserScript(WKUserScript(source: Self.mediaScript.replacingOccurrences(of: "__AIRC_REMOTE_TOKEN__", with: remoteToken), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        profile.userContent.add(self, name: "aircMedia")
    }

    func mediaFrame(of tab: WebKitTab) -> WKFrameInfo? { sessions[ObjectIdentifier(tab)]?.selectedFrame }

    func mute(_ tab: WebKitTab) {
        let script = "window.__aircMedia && window.__aircMedia.setMuted(\(tab.isMuted))"
        tab.webView.evaluateJavaScript(script)
        for (frame, _) in (sessions[ObjectIdentifier(tab)]?.frames ?? [:]).values {
            if !frame.isMainFrame { tab.webView.evaluateJavaScript(script, in: frame, in: .page, completionHandler: nil) }
        }
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
        if let action = body["remoteAction"] as? String {
            guard body["token"] as? String == remoteToken else { return }
            MediaLibrary.shared.media?.nowPlaying.perform(action, value: (body["value"] as? NSNumber)?.doubleValue ?? 0)
            return
        }
        let key = ObjectIdentifier(tab)
        let before = sessions[key]?.session ?? EngineMediaSession()
        let entry = sessions[key] ?? Entry(tab: tab, session: EngineMediaSession())
        let frameID = body["frameID"] as? String ?? "main"
        let newFrame = entry.frames[frameID] == nil
        if body["audible"] as? Bool == true { entry.audibleFrames.insert(frameID) }
        else { entry.audibleFrames.remove(frameID) }
        tab.setAudible(!entry.audibleFrames.isEmpty)
        if body["gone"] as? Bool == true { entry.frames[frameID] = nil }
        else { entry.frames[frameID] = (message.frameInfo, EngineMediaSession(body)) }
        func rank(_ s: EngineMediaSession) -> Int {
            (s.playback == .playing ? 8 : s.playback == .paused ? 4 : 0) + (s.isCall ? 16 : 0) + (s.title.isEmpty ? 0 : 1)
        }
        let selected = entry.frames.values.max { rank($0.1) < rank($1.1) }
        let after = selected?.1 ?? EngineMediaSession()
        entry.session = after; entry.selectedFrame = selected?.0
        sessions = sessions.filter { $0.value.live }
        sessions[key] = entry
        if newFrame && tab.isMuted { mute(tab) }
        if after != before { sessionObservers[key]?(after) }
        if after.isPresent != before.isPresent { tabsObserver?(mediaTabs) }
    }

    func clearSession(of tab: WebKitTab) {
        let key = ObjectIdentifier(tab)
        sessions[key] = nil
        sessionObservers[key]?(EngineMediaSession())
        tabsObserver?(mediaTabs)
    }

    /// Posts {playbackState, title, artist, album, artwork, actions, microphoneActive, cameraActive, capture} on every
    /// change, once per microtask; a new document starts with an empty state.
    static let mediaScript = """
    (function(){
      if (window.__aircMedia) return;
      var frameID = Math.random().toString(36).slice(2), remoteToken = '__AIRC_REMOTE_TOKEN__';
      var ms = navigator.mediaSession, handlers = {}, said = {mic: null, cam: null}, pbs = null, streams = [], queued = false, positionState = null, tabMuted = false;
      var known = new Set(), watched = new WeakSet(), begun = new WeakSet(), originalMute = new WeakMap(), positionAt = performance.now(), wasPlaying = false;
      function post(){ if (queued) return; queued = true; Promise.resolve().then(function(){ queued = false; send(); }); }
      function watch(m) {
        if (watched.has(m)) return; watched.add(m); known.add(new WeakRef(m));
        m.addEventListener('play', function(){ begun.add(m); post(); });
        m.addEventListener('emptied', function(){ begun.delete(m); post(); });
        ['play','playing','pause','ended','emptied','loadeddata','timeupdate','durationchange','ratechange','seeked','volumechange',
         'enterpictureinpicture','leavepictureinpicture','webkitpresentationmodechanged'].forEach(function(e){ m.addEventListener(e, post); });
        if (tabMuted) { originalMute.set(m, m.muted); m.muted = true; }
      }
      function els(){
        document.querySelectorAll('audio,video').forEach(watch);
        var list = []; known.forEach(function(ref){ var m = ref.deref(); if (m) list.push(m); else known.delete(ref); }); return list;
      }
      var play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function(){ watch(this); return play.apply(this, arguments); };
      // The page's own mute (tab mute mutes every element and keeps what the page had).
      function pageMuted(m){ return (tabMuted && originalMute.has(m) ? originalMute.get(m) : m.muted) || m.volume === 0; }
      // What the session's clock and actions follow: the element making the sound, not a muted or looping decoration
      // beside it (Spotify's Canvas next to its detached player), then any playing one, then one that has started.
      function primary(list){
        function rank(m){ return (!m.paused ? 4 : 0) + (pageMuted(m) ? 0 : 2) + (m.loop ? 0 : 1); }
        var best = null;
        list.forEach(function(m){ if ((!m.paused || m.currentTime > 0 || begun.has(m)) && !m.ended && (!best || rank(m) > rank(best))) best = m; });
        return best;
      }
      function live(kind){ return streams.some(function(s){ return s.getTracks().some(function(t){ return t.kind === kind && t.readyState === 'live'; }); }); }
      function send(){
        var md = ms && ms.metadata, list = els();
        var audible = list.some(function(m){ return !m.paused && !m.ended && !m.muted && m.volume > 0 && m.readyState > 2; });
        // Tab mute must not erase the session or stop the clock. Muted autoplay without metadata stays out.
        list = list.filter(function(m){ return tabMuted || md || (!m.muted && m.volume > 0); });
        var m = primary(list), pos = positionState || (m && isFinite(m.duration) && m.duration > 0 ? {duration: m.duration, position: m.currentTime, playbackRate: m.playbackRate} : null);
        var playing = list.some(function(m){ return !m.paused && !m.ended && m.readyState > 2; });
        var started = list.some(function(m){ return (m.currentTime > 0 || !m.paused || begun.has(m)) && !m.ended; });
        var state = m ? (playing ? 'playing' : (started ? 'paused' : 'none')) : (list.length ? 'none' : (pbs || 'none'));
        if (positionState) {
          var now = performance.now();
          if (wasPlaying) positionState.position = Math.min(positionState.duration, positionState.position + (now-positionAt)/1000 * positionState.playbackRate);
          positionAt = now; wasPlaying = state === 'playing';
        }
        var art = md && md.artwork ? Array.prototype.map.call(md.artwork, function(a){ try { return new URL(a.src, location.href).href; } catch (e) { return a.src; } }) : [];
        var acts = Object.keys(handlers);
        if (m && pos && acts.indexOf('seekto') < 0) acts.push('seekto');
        if (state !== 'none') { ['play','pause'].forEach(function(a){ if (acts.indexOf(a) < 0) acts.push(a); }); }
        try { window.webkit.messageHandlers.aircMedia.postMessage({
          frameID: frameID, audible: audible, playbackState: state, active: state === 'playing', title: md ? md.title || '' : '', artist: md ? md.artist || '' : '',
          album: md ? md.album || '' : '', artwork: art, actions: acts,
          duration: pos && pos.duration, position: pos && pos.position, playbackRate: pos ? pos.playbackRate : 1, microphoneActive: said.mic, cameraActive: said.cam,
          capture: {microphone: live('audio'), camera: live('video'), screen: false, tab: false}}); } catch (e) {}
      }
      window.__aircMedia = {setMuted: function(on){
        if (tabMuted === on) return; var list = els(); tabMuted = on;
        list.forEach(function(m){ if (on) { originalMute.set(m, m.muted); m.muted = true; }
          else { m.muted = originalMute.get(m) || false; originalMute.delete(m); } }); post();
      }, perform: function(a, v){
        var h = handlers[a];
        if (h) { try { h({action: a, seekTime: v, seekOffset: v}); post(); } catch (e) {} return true; }
        var list = els(), m = primary(list) || list[0];
        if (!m) return false;
        if (a === 'play') { m.play(); return true; }
        if (a === 'pause') { list.forEach(function(m){m.pause();}); return true; }
        if (a === 'seekto' && isFinite(m.duration)) { m.currentTime = Math.max(0, Math.min(m.duration, v)); post(); return true; }
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
        function remote(a){ return function(e){
          try { window.webkit.messageHandlers.aircMedia.postMessage({remoteAction:a, token:remoteToken, value:e && (e.seekTime || e.seekOffset) || 0}); } catch (_) {}
        }; }
        ms.setActionHandler = function(a, h){
          // WebKit may receive an OS command itself: use the same app-wide destination as Chromium.
          var transport = ['play','pause','nexttrack','previoustrack','seekto','seekbackward','seekforward','stop'].indexOf(a) >= 0;
          try { set && set(a, transport && (h || a === 'play' || a === 'pause') ? remote(a) : h); } catch (e) {}
          if (h) handlers[a] = h; else delete handlers[a]; post();
        };
        ['play','pause'].forEach(function(a){ try { set && set(a, remote(a)); } catch (_) {} });
        var setPosition = ms.setPositionState && ms.setPositionState.bind(ms);
        ms.setPositionState = function(p){
          if (setPosition) setPosition(p);
          positionAt = performance.now(); wasPlaying = pbs === 'playing';
          positionState = p && Number.isFinite(p.duration) && p.duration > 0 ?
            {duration: p.duration, position: p.position || 0, playbackRate: p.playbackRate == null ? 1 : p.playbackRate} : null; post();
        };
        var mic = ms.setMicrophoneActive, cam = ms.setCameraActive;
        ms.setMicrophoneActive = function(v){ said.mic = !!v; post(); try { return mic && mic.call(ms, v); } catch (e) {} };
        ms.setCameraActive = function(v){ said.cam = !!v; post(); try { return cam && cam.call(ms, v); } catch (e) {} };
      }
      var md = navigator.mediaDevices, gum = md && md.getUserMedia ? md.getUserMedia.bind(md) : null;
      if (gum) md.getUserMedia = function(c){ return gum(c).then(function(s){
        streams.push(s); s.getTracks().forEach(function(t){ t.addEventListener('ended', post); var stop = t.stop.bind(t); t.stop = function(){ stop(); post(); }; });
        post(); return s; }); };
      ['play','playing','pause','ended','emptied','loadeddata','timeupdate','durationchange','ratechange','seeked','volumechange',
       'enterpictureinpicture','leavepictureinpicture','webkitpresentationmodechanged'].forEach(function(e){ document.addEventListener(e, post, true); });
      new MutationObserver(function(){ els(); post(); }).observe(document, {childList:true, subtree:true});
      window.addEventListener('pagehide', function(){ try { window.webkit.messageHandlers.aircMedia.postMessage({frameID:frameID, gone:true}); } catch (_) {} });
      try { window.webkit.messageHandlers.aircMedia.postMessage({frameID:frameID, playbackState: 'none'}); } catch (e) {}
    })();
    """
}
