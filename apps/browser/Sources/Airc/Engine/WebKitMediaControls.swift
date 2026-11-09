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
            page.webView.closeAllMediaPresentations(completionHandler: nil)
        default: break
        }
    }
}

/// The system picture in picture window's own buttons reach WebKit (its PIPViewController delegate). For the return
/// button WebKit tells the app first (`_webViewFullscreenMayReturnToInline:`, where Safari selects its tab) and puts the
/// video back inline only once the page is visible, so a hidden tab stays in the window until the app shows it. Airc
/// brings it back as Back to Tab does for Chromium's picture in picture: its window, its Space, the tab selected.
enum SystemPictureInPicture {
    private static let open = NSHashTable<WebKitTab>.weakObjects()
    #if AIRC_TESTING
    /// The tabs WebKit asked to bring back, in order (`--script pipreturn`).
    static var returnRequests: [ObjectIdentifier] = []
    #endif

    static func isOpen(_ page: WebKitTab) -> Bool { open.contains(page) }

    static func changed(_ page: WebKitTab, open now: Bool) {
        if now { open.add(page) } else { open.remove(page) }
        // The tray's menu offers Hide while it's open.
        if let id = MediaLibrary.shared.tabID(for: page) { MediaLibrary.shared.media?.pageChanged(id) }
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
}

extension WebKitTab {
    /// WKUIDelegatePrivate: the system picture in picture's return button, before WebKit puts the video back inline.
    @objc(_webViewFullscreenMayReturnToInline:)
    func aircFullscreenMayReturnToInline(_ webView: WKWebView) {
        SystemPictureInPicture.returnToTab(self)
    }

    /// WKUIDelegatePrivate: a video of this page entered or left the system picture in picture window.
    @objc(_webView:hasVideoInPictureInPictureDidChange:)
    func aircWebView(_ webView: WKWebView, hasVideoInPictureInPictureDidChange open: Bool) {
        SystemPictureInPicture.changed(self, open: open)
    }

    /// Native dismissal can leave document.pictureInPictureElement set even after the video is inline.
    /// Exit the page API too, then finish native dismissal before pausing: leaving PiP can resume playback.
    /// Calls only dismiss; their media and tracks must keep running. WebKit holds a hidden page's exit until the page
    /// shows, so the page API gets a second, and a window still open after it closes natively, playback resumed; the
    /// caller hears back within three seconds whatever WebKit does.
    func closeSystemPictureInPicture(pause: Bool, completion done: (() -> Void)? = nil) {
        var answered = false
        let completion = { if !answered { answered = true; done?() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: completion)
        webView.callAsyncJavaScript("""
        const playing = Array.from(document.querySelectorAll('audio,video')).filter(v => !v.paused && !v.ended);
        playing.forEach(v => { v.__aircResume = true; });
        // The legacy presentation mode changes before standard PiP entry has
        // finished. Closing in that interval can let its queued entry restore a
        // stale pictureInPictureElement after native dismissal. Serialize our
        // exit behind the host's entry promise; the Swift completion is bounded.
        await Promise.all(Array.from(document.querySelectorAll('video')).map(v =>
            Promise.resolve(v.__aircPiPEntry).catch(() => {})));
        if (document.pictureInPictureElement && document.exitPictureInPicture) {
            try { await Promise.race([document.exitPictureInPicture(), new Promise(r => setTimeout(r, 1000))]); } catch (_) {}
        }
        document.querySelectorAll('video').forEach(function(v) {
            if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline');
        });
        // WebKit's system exit can pause a MediaStream video. A call Close must preserve its playback.
        if (!pause) await Promise.all(playing.map(v => v.play().catch(() => {})));
        const open = !!document.pictureInPictureElement;
        if (pause || !open) playing.forEach(v => { delete v.__aircResume; });
        return open;
        """, arguments: ["pause": pause], in: webKitProfile.library.mediaFrame(of: self), in: .page) { [weak self] result in
            guard let self, !self.isClosed else { completion(); return }
            // A call has already exited through the page API; don't issue a second native Close,
            // which can pause the just-restored MediaStream again.
            guard pause || (try? result.get()) as? Bool == true else { completion(); return }
            self.webView.closeAllMediaPresentations {
                guard !pause else { return self.webView.pauseAllMediaPlayback { completion() } }
                self.webView.callAsyncJavaScript("""
                document.querySelectorAll('audio,video').forEach(v => {
                    if (v.__aircResume) { delete v.__aircResume; v.play().catch(() => {}); }
                });
                """, arguments: [:], in: self.webKitProfile.library.mediaFrame(of: self), in: .page) { _ in completion() }
            }
        }
    }

    /// `automatic`: leaving the tab (SB-55), never for a muted video, as Chromium's own. Sound playing from another
    /// element (Spotify's detached player) makes a muted video decoration (its Canvas loop, Apple Music's motion
    /// artwork): that tab goes to the media tray. Tab mute mutes every element, so it can't tell them apart.
    func requestSystemPictureInPicture(automatic: Bool = false, completion: ((String) -> Void)?) {
        webView.callAsyncJavaScript("""
          if (document.pictureInPictureElement) return 'already';
          var videos = Array.prototype.filter.call(document.querySelectorAll('video'), function(v){
            return !v.paused && !v.ended && v.readyState > 2 && !v.disablePictureInPicture; });
          var v = videos.find(function(v){ return !v.muted && v.volume > 0; })
            || (tabMuted || !soundElsewhere && !automatic ? videos[0] : null);
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
        """, arguments: ["automatic": automatic, "tabMuted": isMuted, "soundElsewhere": isAudible && !isMuted],
             in: webKitProfile.library.mediaFrame(of: self), in: .page) { result in
            completion?((try? result.get()) as? String ?? "none")
        }
    }
}
