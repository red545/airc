// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import WebKit

/// WebKit's protected video stays in its system window. Airc's tray offers the Mini Player menu equivalent.
extension MediaCenter {
    func hasSystemMiniPlayer(_ p: Player) -> Bool { library?.page(for: p.tabID) is WebKitTab && !p.isCall }
    func canSuppressSystemMiniPlayer(_ p: Player) -> Bool {
        guard let page = library?.page(for: p.tabID) else { return false }
        return WindowController.canPersistMiniPlayerSite(for: page)
    }
    func systemMiniPlayer(_ action: String, _ p: Player, completion: (() -> Void)? = nil) {
        guard let page = library?.page(for: p.tabID) as? WebKitTab else { return }
        switch action {
        case "pip": page.requestSystemPictureInPicture(completion: nil)
        // Arc's "–": the window goes and the media plays on here in the tray; Picture in Picture brings it back.
        case "hide": page.closeSystemPictureInPicture(pause: false, completion: completion)
        case "close":
            if !p.isCall { perform("pause", p) }
            page.closeSystemPictureInPicture(pause: !p.isCall, completion: completion)
        case "never":
            guard canSuppressSystemMiniPlayer(p) else { return }
            library?.controller?.suppressMiniPlayer(for: page)
            page.closeMediaPresentations()
        default: break
        }
    }
}

/// The system picture in picture window's own buttons reach WebKit (its PIPViewController delegate). For the return
/// button WebKit tells the app first (`_webViewFullscreenMayReturnToInline:`, where Safari selects its tab) and puts the
/// video back inline only once the page is visible, so a hidden tab stays in the window until the app shows it. Airc
/// brings it back as Back to Tab does for Chromium's picture in picture: its window, its Space, the tab selected.
///
/// Opening and closing are serialized. macOS shows one system player at a time, and WebKit drops an entry that
/// arrives while its previous player (AVKit's window, PIPAgent's animation) is still closing. So an open that comes
/// during any tab's close, Return or teardown waits for it (at most `queueTimeout`, then runs and logs why); a newer
/// open replaces a waiting one; opening in one tab first closes another tab's open player; a close cancels a waiting
/// open of its own tab. Each of these writes one log line. Nothing is dropped without an answer.
enum SystemPictureInPicture {
    private static let open = NSHashTable<WebKitTab>.weakObjects()
    /// Pages that had a close or an entry: the ones whose state can block an open.
    private static let tracked = NSHashTable<WebKitTab>.weakObjects()
    private struct QueuedOpen {
        weak var page: WebKitTab?
        let automatic: Bool, forCall: Bool, completion: ((String) -> Void)?
        let serial: Int, since: Date
        var closedOther = false
    }
    private static var queued: QueuedOpen?
    private static var serial = 0
    static let queueTimeout: TimeInterval = 5
    #if AIRC_TESTING
    /// The tabs WebKit asked to bring back, in order (`--script pipreturn`).
    static var returnRequests: [ObjectIdentifier] = []
    static var requestResults: [ObjectIdentifier: String] = [:]
    /// Serialization log lines, in order (`--script pipreturn-rapid`).
    static var events: [String] = []
    static var openCount: Int { open.allObjects.count }
    static var hasQueuedOpen: Bool { queued != nil }
    /// `--script cbfocus` fsrace: a player window still closing for `page` (no window shown, no WebKit call).
    static func setOpenForTesting(_ page: WebKitTab, _ now: Bool) { if now { open.add(page) } else { open.remove(page) } }
    #endif

    static func isOpen(_ page: WebKitTab) -> Bool { open.contains(page) }
    /// Open, entering, or waiting to open: a close has to reach it.
    static func isOpenOrOpening(_ page: WebKitTab) -> Bool {
        open.contains(page) || page.systemPictureInPictureEntry != nil || (queued.map { $0.page === page } ?? false)
    }

    static func changed(_ page: WebKitTab, open now: Bool) {
        if now { open.add(page) } else { open.remove(page) }
        // The tray's menu offers Hide while it's open.
        if let id = MediaLibrary.shared.tabID(for: page) { MediaLibrary.shared.media?.pageChanged(id) }
        if !now { closeFinished() }
    }

    static func returnToTab(_ page: WebKitTab) {
        #if AIRC_TESTING
        returnRequests.append(ObjectIdentifier(page))
        #endif
        guard !page.isClosed, let app = NSApp.delegate as? AppDelegate else { return }
        #if canImport(AircCore)
        // The Chromium build's Back to Tab: Little Arc's mini player, or the window that has the tab.
        if let request = (app.engine as? ChromiumEngine)?.pictureInPictureRequestsTab { return request(page) }
        #endif
        if let little = app.littleArcs.first(where: { $0.page === page }) { return little.restoreFromMiniPlayer() }
        (app.controller(owning: page) ?? app.controller)?.showPictureInPictureTab(page)
    }

    // MARK: Serialization

    static func log(_ line: String) {
        NSLog("Airc picture in picture: %@", line)
        #if AIRC_TESTING
        events.append(line)
        #endif
    }

    static func track(_ page: WebKitTab) { tracked.add(page) }

    /// What an open for `page` has to wait for now, or nil.
    static func blocker(for page: WebKitTab) -> String? {
        for t in tracked.allObjects {
            if t.isClosingSystemPictureInPicture { return t === page ? "this tab's close" : "another tab's close" }
            if t !== page, t.systemPictureInPictureEntry != nil { return "another tab's opening" }
        }
        return nil
    }

    static func openPage(except page: WebKitTab) -> WebKitTab? { open.allObjects.first { $0 !== page } }

    static func enqueue(_ page: WebKitTab, automatic: Bool, forCall: Bool, completion: ((String) -> Void)?, behind why: String) {
        if let old = queued {
            log("an open waiting for a close is replaced by a newer one\(old.page === page ? "" : " from another tab")")
            old.completion?("replaced")
        }
        serial += 1
        let mine = serial
        queued = QueuedOpen(page: page, automatic: automatic, forCall: forCall, completion: completion, serial: mine, since: Date())
        if page.systemPictureInPictureCloses > 0 {
            if !page.systemPictureInPicturePauseSuperseded { log("the close it waits for won't pause playback") }
            page.systemPictureInPicturePauseSuperseded = true
        }
        log("open waits for \(why)")
        DispatchQueue.main.asyncAfter(deadline: .now() + queueTimeout) { timedOut(mine) }
    }

    /// A close or entry finished: run the waiting open once nothing blocks it.
    static func closeFinished() { DispatchQueue.main.async { drain() } }

    private static func drain() {
        guard var q = queued else { return }
        guard let page = q.page, !page.isClosed else {
            queued = nil
            log("a waiting open is answered none: its tab is gone")
            q.completion?("none")
            return
        }
        guard blocker(for: page) == nil else { return }
        if let other = openPage(except: page), !q.closedOther {
            q.closedOther = true
            queued = q
            log("open closes another tab's player first")
            other.closeMediaPresentations()
            return
        }
        queued = nil
        log(String(format: "open runs after waiting %.2f s", Date().timeIntervalSince(q.since)))
        page.beginSystemPictureInPictureEntry(automatic: q.automatic, forCall: q.forCall, completion: q.completion)
    }

    private static func timedOut(_ mine: Int) {
        guard let q = queued, q.serial == mine else { return }
        queued = nil
        guard let page = q.page, !page.isClosed else { q.completion?("none"); return }
        log(String(format: "open waited %.0f s for %@ and runs now", queueTimeout, blocker(for: page) ?? "a close that just finished"))
        page.beginSystemPictureInPictureEntry(automatic: q.automatic, forCall: q.forCall, completion: q.completion)
    }

    static func cancelQueuedOpen(for page: WebKitTab, because why: String) {
        guard let q = queued, q.page === page else { return }
        queued = nil
        log("a waiting open is cancelled: \(why)")
        q.completion?("cancelled")
    }
}

extension WebKitTab {
    /// WKUIDelegatePrivate: the system picture in picture's return button, before WebKit puts the video back inline.
    @objc(_webViewFullscreenMayReturnToInline:)
    func aircFullscreenMayReturnToInline(_ webView: WKWebView) {
        SystemPictureInPicture.track(self)
        nativePictureInPictureReturnInFlight = true
        SystemPictureInPicture.returnToTab(self)
    }

    /// WKUIDelegatePrivate: a video of this page entered or left the system picture in picture window.
    @objc(_webView:hasVideoInPictureInPictureDidChange:)
    func aircWebView(_ webView: WKWebView, hasVideoInPictureInPictureDidChange open: Bool) {
        if !open { nativePictureInPictureReturnInFlight = false }
        SystemPictureInPicture.changed(self, open: open)
    }

    /// Tray dismissal shares the page/native exit transaction with Return and
    /// tab teardown. Only change playback after PiP has finished restoring inline.
    /// The whole close, its playback step included, blocks a new open (SystemPictureInPicture).
    func closeSystemPictureInPicture(pause: Bool, completion done: (() -> Void)? = nil) {
        SystemPictureInPicture.track(self)
        SystemPictureInPicture.cancelQueuedOpen(for: self, because: "its tab's player was closed after it")
        systemPictureInPictureCloses += 1
        systemPictureInPicturePauseSuperseded = false
        var answered = false
        let completion = { [self] in
            guard !answered else { return }
            answered = true
            systemPictureInPictureCloses -= 1
            done?()
            SystemPictureInPicture.closeFinished()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: completion)
        let frame = webKitProfile.library.mediaFrame(of: self)
        webView.callAsyncJavaScript("""
            document.querySelectorAll('audio,video').forEach(v => {
                if (!v.paused && !v.ended) v.__aircResume = true;
            });
            """, arguments: [:], in: frame, in: .page) { [self] _ in
            closeMediaPresentations { [self] in
                guard !isClosed else { completion(); return }
                if pause, !systemPictureInPicturePauseSuperseded { return webView.pauseAllMediaPlayback { completion() } }
                if pause { return completion() }
                webView.callAsyncJavaScript("""
                    await Promise.all(Array.from(document.querySelectorAll('audio,video')).map(v => {
                        if (v.__aircResume) { delete v.__aircResume; return v.play().catch(() => {}); }
                    }));
                    """, arguments: [:], in: frame, in: .page) { _ in completion() }
            }
        }
    }

    /// `automatic`: leaving the tab (SB-55), never for a muted video, as Chromium's own. Sound playing from another
    /// element (Spotify's detached player) makes a muted video decoration (its Canvas loop, Apple Music's motion
    /// artwork): that tab goes to the media tray. Tab mute mutes every element, so it can't tell them apart.
    /// An explicit call action may select muted remote video even while separate call audio is playing.
    /// Answers "requested" once the system player is open, "already", "none", "unsupported", or for a request that
    /// waited for a close: "replaced" (a newer open came) or "cancelled" (a close came after it).
    func requestSystemPictureInPicture(automatic: Bool = false, forCall: Bool = false, completion: ((String) -> Void)?) {
        guard !isClosed else { completion?("none"); return }
        if let why = SystemPictureInPicture.blocker(for: self) {
            return SystemPictureInPicture.enqueue(self, automatic: automatic, forCall: forCall, completion: completion, behind: why)
        }
        // This tab's entry is running (and no close came after it): the same open, one answer for both.
        if let entry = systemPictureInPictureEntry { systemPictureInPictureEntry = entry + [completion]; return }
        if let other = SystemPictureInPicture.openPage(except: self) {
            SystemPictureInPicture.enqueue(self, automatic: automatic, forCall: forCall, completion: completion,
                                           behind: "another tab's player to close")
            other.closeMediaPresentations()
            return
        }
        beginSystemPictureInPictureEntry(automatic: automatic, forCall: forCall, completion: completion)
    }

    func beginSystemPictureInPictureEntry(automatic: Bool, forCall: Bool, completion: ((String) -> Void)?) {
        SystemPictureInPicture.track(self)
        systemPictureInPictureEntry = [completion]
        runSystemPictureInPictureEntry(automatic: automatic, forCall: forCall, reconciled: false)
    }

    private func finishSystemPictureInPictureEntry(_ answer: String) {
        let callbacks = systemPictureInPictureEntry ?? []
        systemPictureInPictureEntry = nil
        #if AIRC_TESTING
        SystemPictureInPicture.requestResults[ObjectIdentifier(self)] = answer
        #endif
        callbacks.forEach { $0?(answer) }
        SystemPictureInPicture.closeFinished()
    }

    /// Polls (50 ms) until `ready` or a close of this tab starts, at most `seconds`.
    private func awaitSystemPictureInPicture(_ seconds: Double, _ ready: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        func poll() {
            if ready() { return then(true) }
            if isClosed || systemPictureInPictureCloses > 0 || Date() > deadline { return then(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }

    private func runSystemPictureInPictureEntry(automatic: Bool, forCall: Bool, reconciled: Bool) {
        guard !isClosed else { return finishSystemPictureInPictureEntry("none") }
        webView.callAsyncJavaScript("""
          if (reconciled) {
            for (const v of document.querySelectorAll('video')) {
              if (v.__aircStaleResume) { delete v.__aircStaleResume; if (v.paused && !v.ended) await v.play().catch(() => {}); }
            }
          }
          const existing = document.pictureInPictureElement;
          if (existing) {
            // An entry in flight (its promise can resolve before WebKit's native notification) is opening, not stale.
            if (existing.__aircPiPEntry) { try { await existing.__aircPiPEntry; return 'requested'; } catch (_) { return 'none'; } }
            if (!nativeOpen && !reconciled) { if (!existing.paused && !existing.ended) existing.__aircStaleResume = true; return 'stale'; }
            return 'already';
          }
          var videos = Array.prototype.filter.call(document.querySelectorAll('video'), function(v){
            return !v.paused && !v.ended && v.readyState > 2 && !v.disablePictureInPicture; });
          var v = videos.find(function(v){ return !v.muted && v.volume > 0; })
            || (tabMuted || !automatic && (!soundElsewhere || forCall) ? videos[0] : null);
          if (!v) return 'none';
          if (v.webkitPresentationMode === 'picture-in-picture') return 'already';
          // Pair the standard entry/exit APIs when available. Mixing legacy entry with native exit can
          // leave document.pictureInPictureElement stale after WebKit has returned the video inline.
          if (v.requestPictureInPicture) {
            let entry;
            try {
              entry = v.requestPictureInPicture(); v.__aircPiPEntry = entry;
              await entry; return 'requested';
            } catch (_) {}
            finally { if (v.__aircPiPEntry === entry) delete v.__aircPiPEntry; }
          }
          if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
            v.webkitSetPresentationMode('picture-in-picture'); return 'requested';
          }
          return 'unsupported';
        """, arguments: ["automatic": automatic, "forCall": forCall, "tabMuted": isMuted, "soundElsewhere": isAudible && !isMuted,
                         "nativeOpen": SystemPictureInPicture.isOpen(self), "reconciled": reconciled],
             in: webKitProfile.library.mediaFrame(of: self), in: .page) { [self] result in
            if case .failure(let error) = result {
                SystemPictureInPicture.log("entry script failed: \((error as NSError).domain) \((error as NSError).code)")
            }
            let answer = (try? result.get()) as? String ?? "none"
            switch answer {
            case "requested":
                // The page's promise can settle before WebKit's native notification: answer once the player is open.
                awaitSystemPictureInPicture(3, { SystemPictureInPicture.isOpen(self) }) { [self] opened in
                    if !opened, systemPictureInPictureCloses == 0, !isClosed {
                        SystemPictureInPicture.log("entry resolved but no system player opened within 3 s")
                    }
                    finishSystemPictureInPictureEntry(answer)
                }
            case "stale":
                // The page says picture in picture but WebKit has no player: wait for a late notification, then
                // close the leftover presentation and open again (once), keeping the video playing.
                awaitSystemPictureInPicture(1, { SystemPictureInPicture.isOpen(self) }) { [self] opened in
                    if opened || isClosed || systemPictureInPictureCloses > 0 { return finishSystemPictureInPictureEntry(opened ? "already" : "none") }
                    SystemPictureInPicture.log("the page reports picture in picture without a system player; closing it and opening again")
                    closeMediaPresentations { [self] in runSystemPictureInPictureEntry(automatic: automatic, forCall: forCall, reconciled: true) }
                }
            default:
                finishSystemPictureInPictureEntry(answer)
            }
        }
    }
}
