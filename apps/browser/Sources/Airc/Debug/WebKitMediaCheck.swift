// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
import MediaPlayer
import WebKit

extension SnapshotRunner {
    /// No accounts, devices, focus changes or screen capture. A listed loopback host exercises the hybrid adapter.
    func webKitMediaScenario() {
        var server: MediaLibServer?, port: UInt16 = 0
        var music = "", other = "", chromium = ""
        var media: MediaCenter? { MediaLibrary.shared.media }
        func page() -> WebKitTab? { c.engineTab(for: music) as? WebKitTab }
        func player() -> MediaCenter.Player? { media?.sessions[music] }
        func evaluate(_ js: String, _ test: @escaping (Any?) -> Bool, _ label: String) {
            step { [self] done in
                guard let p = page() else { check(false, "webkitmedia: missing WebKit page"); return done() }
                p.evaluate(js) { value in self.check(test(value), "webkitmedia: " + label + " (\(value ?? "nil"))"); done() }
            }
        }
        run { ProtectedMedia.shared.testHosts = ["localhost"] }
        step { done in server = MediaLibServer(); server?.start { port = $0 ?? 0; done() } }
        run { [self] in
            do {
                music = try c.store.openTab(url: "http://localhost:\(port)/music", inSpace: c.currentSpaceID).id
                other = try c.store.openTab(url: "data:text/html,<title>Notes</title>", inSpace: c.currentSpaceID).id
                c.reloadAll(animated: false); c.show(music, focus: false)
            } catch { check(false, "webkitmedia: setup \(error)") }
        }
        step { [self] done in waitUntil({ page()?.isLoading == false && page()?.title.contains("Music") == true }, timeout: 15) { done() } }
        evaluate("a.play(); true", { $0 as? Bool == true }, "start silent audio")
        step { [self] done in waitUntil({ player()?.session.playback == .playing }, timeout: 10) { done() } }
        run { [self] in c.show(other, focus: false) }
        wait(0.5)
        run { [self] in
            check(page() != nil, "webkitmedia: listed service uses WebKit")
            check(media?.players.contains { $0.tabID == music && $0.title == "Fixture Song" && $0.session.artwork.first?.hasSuffix("/art.png") == true } == true,
                  "webkitmedia: tray title and artwork")
            check((player()?.session.duration ?? 0) > 0 && player()?.session.actions.contains("seekto") == true, "webkitmedia: element duration and seek fallback")
            check(page()?.isAudible == true, "webkitmedia: tab speaker state")
            if let p = player() { media?.togglePlayback(p) }
        }
        wait(0.5)
        evaluate("a.paused", { $0 as? Bool == true }, "tray pause reaches element")
        step { [self] done in
            page()?.webView.requestMediaPlaybackState { state in
                self.check(state == .paused, "webkitmedia: WebKit confirms all-media pause (\(state.rawValue))")
                done()
            }
        }
        run { if let p = player() { media?.perform("seekto", p, value: 3); media?.perform("nexttrack", p) } }
        wait(0.3)
        evaluate("a.currentTime >= 2.9 && a.currentTime <= 3.1 && track === 2", { $0 as? Bool == true }, "tray seek and next reach page")
        run { if let p = player() { media?.perform("previoustrack", p); media?.toggleMute(p); media?.togglePlayback(p) } }
        wait(0.5)
        evaluate("a.muted && !a.paused && track === 1", { $0 as? Bool == true }, "previous, mute and resume reach page")
        run { [self] in
            check(player()?.session.playback == .playing && page()?.isMuted == true, "webkitmedia: mute retains playing session")
            check(media?.nowPlaying.tabID == music, "webkitmedia: last-playing target is WebKit")
            check(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Fixture Song", "webkitmedia: Now Playing metadata")
            media?.nowPlaying.perform("pause")
        }
        wait(0.5)
        evaluate("a.paused", { $0 as? Bool == true }, "shared remote pause reaches WebKit")
        // No Media Session position handler: the element clock is the source. Explicit positions also propagate.
        evaluate("navigator.mediaSession.setPositionState({duration:120, position:42, playbackRate:1.5}); true", { $0 as? Bool == true }, "page sets position")
        wait(0.2)
        run { [self] in check(player()?.session.duration == 120 && player()?.session.position == 42 && player()?.session.rate == 1.5, "webkitmedia: Media Session position bridge") }
        evaluate("navigator.mediaSession.setPositionState(); true", { $0 as? Bool == true }, "clear position uses element again")
        // A canvas stream is a real non-DRM video, without a device or capture permission.
        evaluate("""
        var cv=document.createElement('canvas');cv.width=320;cv.height=180;
        var ctx=cv.getContext('2d');ctx.fillStyle='#536bc0';ctx.fillRect(0,0,320,180);
        window.v=document.createElement('video');v.playsInline=true;v.srcObject=cv.captureStream(10);document.body.appendChild(v);
        window.paint=setInterval(function(){ctx.fillRect(0,0,320,180)},100);v.play();true
        """, { $0 as? Bool == true }, "start synthetic video")
        wait(1)
        run { [self] in c.show(music, focus: false); c.show(other, focus: false) }
        step { [self] done in
            page()?.requestSystemPictureInPicture { result in
                self.note("webkitmedia: explicit system PiP request \(result); background window key=\(self.c.window.isKeyWindow)")
                done()
            }
        }
        wait(0.5)
        evaluate("document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture'", { $0 as? Bool == true }, "system video PiP opens")
        step { [self] done in
            check(player().map { media?.hasSystemMiniPlayer($0) == true } == true, "webkitmedia: Airc menu equivalent available")
            guard let p = player(), let media else { check(false, "webkitmedia: missing Close target"); return done() }
            media.systemMiniPlayer("close", p, completion: done)
        }
        evaluate("v.paused && !document.pictureInPictureElement && v.webkitPresentationMode !== 'picture-in-picture'", { $0 as? Bool == true }, "Close menu pauses video and dismisses PiP")
        // The same system presentation must dismiss without pausing a call's synthetic video.
        evaluate("v.play();true", { $0 as? Bool == true }, "restart video for call Close")
        wait(0.3)
        step { done in page()?.requestSystemPictureInPicture { _ in done() } }
        wait(0.5)
        evaluate("document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture'", { $0 as? Bool == true }, "call system PiP opens")
        step { [self] done in
            guard var p = player(), let media else { check(false, "webkitmedia: missing call Close target"); return done() }
            p.session.actions.insert("hangup")
            check(p.isCall, "webkitmedia: call Close target is a call")
            media.systemMiniPlayer("close", p, completion: done)
        }
        evaluate("JSON.stringify({playing:!v.paused, pip:!!document.pictureInPictureElement, mode:v.webkitPresentationMode})", {
            guard let json = $0 as? String, let state = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return false }
            return state["playing"] as? Bool == true && state["pip"] as? Bool == false && state["mode"] as? String != "picture-in-picture"
        }, "call Close dismisses PiP and keeps playback")
        evaluate("v.pause();true", { $0 as? Bool == true }, "stop synthetic video")
        evaluate("window.fr=document.createElement('iframe');fr.src='/music';document.body.appendChild(fr);true", { $0 as? Bool == true }, "embedded player loads")
        wait(1)
        evaluate("fr.contentWindow.a.play();true", { $0 as? Bool == true }, "embedded player starts")
        wait(0.5)
        run { if let p = player() { media?.perform("nexttrack", p) } }
        wait(0.3)
        evaluate("fr.contentWindow.track === 2", { $0 as? Bool == true }, "tray action reaches playing subframe")
        evaluate("fr.remove();window.detached=new Audio('/silence.wav');detached.loop=true;detached.play();true", { $0 as? Bool == true }, "detached Audio starts")
        wait(0.5)
        run { [self] in check(player()?.session.playback == .playing && page()?.isMuted == true, "webkitmedia: detached element remains tracked and tab-muted") }
        evaluate("detached.muted", { $0 as? Bool == true }, "new detached element inherits mute")
        evaluate("detached.pause();true", { $0 as? Bool == true }, "detached element stops")
        #if canImport(AircCore)
        run { [self] in
            if app?.engine is ChromiumEngine {
                chromium = (try? c.store.openTab(url: "http://127.0.0.1:\(port)/music", inSpace: c.currentSpaceID).id) ?? ""
                c.reloadAll(animated: false); c.show(chromium, focus: false)
            }
        }
        step { [self] done in
            if chromium.isEmpty { return done() }
            waitUntil({ media?.sessions[chromium]?.session.playback == .playing }, timeout: 10) { done() }
        }
        run { [self] in
            if !chromium.isEmpty { check(media?.nowPlaying.tabID == chromium, "webkitmedia: latest Chromium session takes remote commands") }
            media?.nowPlaying.perform("pause")
            if let p = player() { media?.perform("play", p) }
        }
        wait(0.5)
        run { [self] in
            check(media?.nowPlaying.tabID == music, "webkitmedia: resuming WebKit retakes remote commands")
        }
        #endif
        // Private playback is intentionally absent from the ordinary tray/publisher. A separate
        // loopback server makes every artwork request attributable to this private session.
        var privateWindow: PrivateWindowController?, privatePage: EngineTab?
        var privateServer: MediaLibServer?, privatePort: UInt16 = 0
        step { done in privateServer = MediaLibServer(); privateServer?.start { privatePort = $0 ?? 0; done() } }
        step { [self] done in
            guard let app else { check(false, "webkitmedia: missing app"); return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                privatePage = w?.openPage(URL(string: "http://127.0.0.1:\(privatePort)/music"))
                done()
            }
        }
        step { [self] done in
            waitUntil({ privatePage?.isLoading == false && privatePage?.title.contains("Music") == true }, timeout: 15) { done() }
        }
        // Chromium defers a media load in a hidden page that hasn't played yet, and Airc hides pages in windows that
        // are covered or off the active Space. Then play() can stay pending (readyState 0) far beyond the 10 s
        // DevTools reply. Note the page's state, poll play()'s outcome with its own deadline, and in ship runs count
        // a failure as FAIL-ENV only while the private window itself can't be seen.
        var privateState = "?"
        func privateCheck(_ ok: Bool, _ what: String) {
            let w = privateWindow?.window
            let why = Self.screenLocked ? "the screen is locked"
                : w.map { !$0.isOnActiveSpace ? "the private window isn't on the active Space"
                    : $0.occlusionState.contains(.visible) ? nil : "the private window is covered" } ?? nil
            if !ok, ProcessInfo.processInfo.environment["AIRC_SHIP_GATE"] == "1", let why {
                return note("FAIL-ENV \(what) (\(why); page \(privateState))")
            }
            check(ok, what)
        }
        step { [self] done in
            let started = Date()
            func poll() {
                guard let privatePage else { return done() }
                privatePage.evaluate("document.visibilityState + ', readyState ' + a.readyState") { value in
                    privateState = value as? String ?? "?"
                    if privateState.hasSuffix("readyState 4") || Date().timeIntervalSince(started) > 5 {
                        self.note("webkitmedia: private page \(privateState) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                        return done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
                }
            }
            poll()
        }
        // Match a person's Play gesture and require admission. Fire-and-forget evaluation plus a fixed
        // one-second delay can check a cold private renderer before its play() promise has settled.
        step { [self] done in
            guard let privatePage else { check(false, "webkitmedia: missing private page"); return done() }
            #if canImport(AircCore)
            if let chromium = app?.engine as? ChromiumEngine, privatePage is ChromiumTab {
                let js = "window.__privatePlay = 'pending'; a.play().then(() => { window.__privatePlaybackStart = a.currentTime; " +
                    "window.__privatePlay = true; }).catch(e => { window.__privatePlay = String(e); }); true"
                chromium.devToolsCall("Runtime.evaluate", params: ["expression": js, "userGesture": true,
                                      "returnByValue": true], in: privatePage) { reply, error in
                    let started = Date()
                    func poll() {
                        privatePage.evaluate("[window.__privatePlay, document.visibilityState + ', readyState ' + a.readyState]") { value in
                            let pair = value as? [Any], result = pair?.first, settled = result != nil && (result as? String) != "pending"
                            privateState = pair?.last as? String ?? privateState
                            if settled || Date().timeIntervalSince(started) > 30 {
                                privateCheck(result as? Bool == true, "webkitmedia: private Play gesture succeeds (\(result ?? error ?? "nil") after \(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
                                return done()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
                        }
                    }
                    poll()
                }
                return
            }
            #endif
            guard let webkit = privatePage as? WebKitTab else { check(false, "webkitmedia: unknown private engine"); return done() }
            webkit.webView.callAsyncJavaScript("await a.play(); window.__privatePlaybackStart = a.currentTime; return true;",
                                              arguments: [:], in: nil, in: .page) { result in
                privateCheck((try? result.get()) as? Bool == true, "webkitmedia: private Play gesture succeeds (\(result))")
                done()
            }
        }
        wait(1)
        step { [self] done in
            guard let privatePage else { check(false, "webkitmedia: missing private page"); return done() }
            privatePage.evaluate("!a.paused && a.currentTime > 0 && a.currentTime !== window.__privatePlaybackStart") { result in
                privateCheck(result as? Bool == true, "webkitmedia: private fixture is playing")
                done()
            }
        }
        run { [self] in
            let url = URL(string: "http://127.0.0.1:\(privatePort)/art.png")!
            check(privatePage.flatMap { MediaLibrary.shared.tabID(for: $0) } == nil,
                  "webkitmedia: private page has no ordinary media identity")
            check(!FaviconCache.shared.networkRequests.contains(url), "webkitmedia: private artwork never requested by shared session")
            check(!FaviconCache.shared.diskWrites.contains(url), "webkitmedia: private artwork never written to disk")
            check(FaviconCache.shared.fileForTesting(url).map { !FileManager.default.fileExists(atPath: $0.path) } == true,
                  "webkitmedia: private artwork absent from disk cache")
            check(media?.players.allSatisfy { $0.pageURL != privatePage?.url?.absoluteString } == true,
                  "webkitmedia: private playback excluded from ordinary tray")
            note("webkitmedia: private artwork loopback requests (engine permitted): \(privateServer?.artworkRequestCount ?? -1); shared requests: 0")
            privateWindow?.closeWindow()
        }
        step { [self] done in
            waitUntil({ privatePage?.isClosed == true }, timeout: 5) { done() }
        }
        run { [self] in
            check(privatePage?.isClosed == true, "webkitmedia: closing private window destroys media page")
            privatePage = nil; privateWindow = nil; privateServer?.stop(); privateServer = nil
        }
        run { [self] in
            c.closeTab(music); if !chromium.isEmpty { c.closeTab(chromium) }
            server?.stop(); ProtectedMedia.shared.testHosts = []
        }
        wait(0.3)
        run { [self] in check(media?.sessions[music] == nil, "webkitmedia: close removes session and remote destination") }
    }
}
#endif
