// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
import MediaPlayer
import WebKit

extension SnapshotRunner {
    /// Loopback audio and synthetic peers only. Commands use the same destination as MPRemoteCommandCenter.
    /// No activation, global input, devices or screen capture. Fullscreen/desktop movement needs an attended run.
    func parityP16aScenario() {
        if script == "parityp16a-video" { parityP16aVideoScenario(); return }
        var main: WindowController?, second: WindowController?
        var owner: WindowController { main ?? c }
        var server: MediaLibServer?, port: UInt16 = 0
        var first = "", latest = "", other = "", call = "", preload = ""
        var media: MediaCenter? { MediaLibrary.shared.media }
        let calls = MediaLibrary.shared.calls
        var foreground: pid_t?
        func page(_ id: String) -> EngineTab? { MediaLibrary.shared.page(for: id) }
        func controls() -> PiPControlsView? { (calls.window as? CallPanel)?.view.controls }
        func verdict(_ ok: Bool, _ message: String, window: NSWindow? = nil) {
            let w = window ?? owner.window
            let why = Self.screenLocked ? "locked display" : !w.isOnActiveSpace ? "off the active Space"
                : !w.occlusionState.contains(.visible) ? "covered window" : nil
            if let why { note("FAIL-ENV parityp16a: \(message) (\(why); underlying \(ok))") }
            else { check(ok, "parityp16a: " + message) }
        }
        func expect(_ message: String, window: (() -> NSWindow?)? = nil, _ condition: @escaping () -> Bool) {
            step { [self] done in
                waitUntil(condition, timeout: 10) {
                    if !condition() { self.note("parityp16a states: first=\(String(describing: media?.sessions[first]?.session.playback)), latest=\(String(describing: media?.sessions[latest]?.session.playback)), targetFirst=\(media?.nowPlaying.tabID == first), targetLatest=\(media?.nowPlaying.tabID == latest)") }
                    verdict(condition(), message, window: window?()); done()
                }
            }
        }
        func js(_ id: @escaping () -> String, _ expression: String, _ message: String? = nil) {
            step { done in
                guard let p = page(id()) else { verdict(false, "missing fixture page"); return done() }
                p.evaluate(expression) { value in
                    if let message { verdict(value as? Bool == true, message + " (\(value ?? "nil"))", window: second?.window) }
                    done()
                }
            }
        }
        func establishedPlayback(_ id: @escaping () -> String) {
            step { done in
                let started = Date()
                func poll() {
                    guard let p = page(id()) else { verdict(false, "missing audio fixture"); return done() }
                    p.evaluate("!a.paused && a.currentTime > 0.3") { value in
                        if value as? Bool == true || Date().timeIntervalSince(started) > 10 {
                            verdict(value as? Bool == true, "audio clock advances before command routing", window: second?.window)
                            return done()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
                    }
                }
                poll()
            }
        }
        run { [self] in
            main = c; foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            ProtectedMedia.shared.testHosts = ["localhost"]
            CallWindowController.followsWindowVisibility = false
            note("parityp16a: active=\(NSApp.isActive), Space=\(owner.window.isOnActiveSpace), visible=\(owner.window.occlusionState.contains(.visible))")
        }
        step { done in server = MediaLibServer(); server?.start { port = $0 ?? 0; done() } }
        run {
            preload = (try? owner.store.openTab(url: "http://localhost:\(port)/dl", inSpace: owner.currentSpaceID).id) ?? ""
            owner.reloadAll(animated: false); owner.show(preload, focus: false)
        }
        expect("preload fixture document loads") { page(preload)?.isLoading == false }
        js({ preload }, "window.a=document.createElement('audio'); a.preload='auto'; a.src='/silence.wav'; document.body.appendChild(a); true")
        wait(0.6)
        js({ preload }, "a.paused && a.currentTime === 0", "preloaded element has never played")
        run { verdict(media?.sessions[preload] == nil && media?.nowPlaying.tabID == nil, "never-played media creates no Now Playing entry") }
        step { done in
            guard let p = page(preload) as? WebKitTab else { verdict(false, "missing preload WebKit page"); return done() }
            p.webView.callAsyncJavaScript("await a.play(); a.pause(); a.currentTime=0; return true;", arguments: [:], in: nil, in: .page) { _ in done() }
        }
        expect("first play then pause at zero retains session and remote destination") {
            media?.sessions[preload]?.session.playback == .paused && media?.nowPlaying.tabID == preload
        }
        run { media?.nowPlaying.perform("play") }
        expect("remote Play resumes the paused-at-zero element") { media?.sessions[preload]?.session.playback == .playing }
        js({ preload }, "a.pause(); a.src='/silence.wav?replacement'; a.load(); true")
        expect("emptied new source drops the old session") { media?.sessions[preload] == nil && media?.nowPlaying.tabID == nil }
        run { owner.closeTab(preload) }
        run { [self] in
            do {
                first = try owner.store.openTab(url: "http://localhost:\(port)/music", inSpace: owner.currentSpaceID).id
                other = try owner.store.openTab(url: "data:text/html,<title>Notes</title>", inSpace: owner.currentSpaceID).id
                owner.reloadAll(animated: false); owner.show(first, focus: false)
            } catch { verdict(false, "setup \(error)") }
        }
        expect("Safari-engine session plays") { media?.sessions[first]?.session.playback == .playing }
        establishedPlayback({ first })
        run { verdict(page(first) is WebKitTab && media?.nowPlaying.tabID == first, "Safari-engine owns Now Playing") }
        run { [self] in
            let space = (try? owner.store.createSpace(name: "Media checks", after: owner.currentSpaceID).id) ?? owner.currentSpaceID
            second = app?.openNewWindow(from: owner, spaceID: space, commandBar: false)
            latest = (try? owner.store.openTab(url: "http://127.0.0.1:\(port)/music?n=2", inSpace: space).id) ?? ""
            second?.reloadAll(animated: false); second?.show(latest, focus: false)
        }
        expect("latest session in second window owns commands", window: { second?.window }) {
            media?.sessions[latest]?.session.playback == .playing && media?.nowPlaying.tabID == latest
        }
        establishedPlayback({ latest })
        run {
            verdict(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Fixture Song (2)",
                    "Now Playing publishes second-window metadata", window: second?.window)
            media?.nowPlaying.perform("toggle")
        }
        expect("remote toggle pauses latest only", window: { second?.window }) {
            media?.sessions[latest]?.session.playback == .paused && media?.sessions[first]?.session.playback == .playing
        }
        js({ latest }, "a.paused", "latest page confirms remote pause")
        run { media?.nowPlaying.perform("play") }
        expect("remote play resumes retained destination", window: { second?.window }) { media?.sessions[latest]?.session.playback == .playing }
        run { page(latest)?.load(URL(string: "about:blank")!) }
        expect("ending latest document hands control back", window: { second?.window }) {
            media?.sessions[latest] == nil && media?.nowPlaying.tabID == first
        }
        run { page(latest)?.load(URL(string: "http://127.0.0.1:\(port)/music?n=2")!) }
        expect("replacement document retakes commands", window: { second?.window }) {
            media?.sessions[latest]?.session.playback == .playing && media?.nowPlaying.tabID == latest
        }
        run { second?.closeTab(latest) }
        expect("close hands commands back to previous session", window: { second?.window }) {
            media?.sessions[latest] == nil && media?.nowPlaying.tabID == first
        }
        run {
            second?.window.performClose(nil); second = nil
            MediaLibrary.shared.follow(owner); owner.window.orderFront(nil)
            media?.nowPlaying.perform("pause")
        }
        expect("handoff pause reaches previous engine") { media?.sessions[first]?.session.playback == .paused }
        js({ first }, "a.paused", "previous page confirms handoff pause")
        // Navigation tears down the media document, including its metadata and action handlers.
        run { page(first)?.load(URL(string: "about:blank")!) }
        expect("unloaded document clears Now Playing and remote commands") {
            media?.sessions[first] == nil && media?.nowPlaying.tabID == nil
                && MPNowPlayingInfoCenter.default().nowPlayingInfo == nil
                && !MPRemoteCommandCenter.shared().togglePlayPauseCommand.isEnabled
        }
        run { verdict(media?.nowPlaying.perform("toggle") == false, "empty remote destination rejects commands") }
        run { page(first)?.load(URL(string: "http://localhost:\(port)/music")!) }
        expect("media restarts before tab unload") { media?.sessions[first]?.session.playback == .playing }
        establishedPlayback({ first })
        run { media?.nowPlaying.perform("pause") }
        expect("unload fixture is paused") { media?.sessions[first]?.session.playback == .paused }
        run { owner.show(other, focus: false); owner.unloadPage(first) }
        expect("unloading the paused tab clears Now Playing") {
            page(first) == nil && media?.sessions[first] == nil && media?.nowPlaying.tabID == nil
                && MPNowPlayingInfoCenter.default().nowPlayingInfo == nil
        }
        // Call teardown while the PiP is hidden, then while its browser window is ordered out.
        for hideBrowser in [false, true] {
            run {
                call = (try? owner.store.openTab(url: "http://127.0.0.1:\(port)/call", inSpace: owner.currentSpaceID).id) ?? ""
                owner.reloadAll(animated: false); owner.show(call, focus: false)
            }
            expect("synthetic call connects") { page(call)?.title.contains("(live)") == true && media?.sessions[call]?.isCall == true }
            run {
                if hideBrowser { owner.window.orderOut(nil); calls.windowVisibility(false) }
                else { owner.show(other, focus: false) }
            }
            step { [self] done in waitUntil({ calls.isShowing }, timeout: 5) { done() } }
            wait(0.6)
            expect("call detaches on \(hideBrowser ? "window hiding" : "tab leave")", window: { calls.window }) { calls.isShowing }
            run {
                verdict(calls.window?.level == .normal && calls.window?.collectionBehavior.contains(.canJoinAllApplications) == false,
                        "automated call stays at normal level on its own Space", window: calls.window)
                if !hideBrowser { controls()?.hide.action?() }
            }
            js({ call }, "hangup(); true")
            // The intentionally hidden window is restored before evaluating visibility-dependent verdicts.
            wait(1)
            run { if hideBrowser { owner.window.orderFront(nil); calls.windowVisibility(true) } }
            wait(0.6)
            expect("call ending while \(hideBrowser ? "browser" : "PiP") hidden releases presentation") {
                calls.tabID == nil && calls.page == nil && !calls.isShowing && page(call).map { !HiddenMiniPlayers.isHidden($0) } == true
            }
            run {
                verdict(media?.sessions[call]?.isCall != true, "ended call removed from call controls")
                owner.closeTab(call)
            }
        }
        run { [self] in
            verdict(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                    "all commands preserve foreground application")
            note("IMPOSSIBLE parityp16a: native fullscreen, app switching and moving between desktops require activation/Space changes forbidden for unattended checks")
            owner.closeTab(first); owner.closeTab(other)
            ProtectedMedia.shared.testHosts = []; server?.stop()
            CallWindowController.followsWindowVisibility = true
        }
        parityP16aVideoScenario()
        parityP16aSystemVideoScenario()
    }
}

extension SnapshotRunner {
    private func parityP16aVideoScenario() {
        #if canImport(AircCore)
        guard let chromium = app?.engine as? ChromiumEngine else { return }
        // Do not open a PiP at all until the framework's pre-show test guard is installed.
        guard c.window.responds(to: NSSelectorFromString("aircProductionPiPConfiguration")) else {
            note("MISSING parityp16a: guarded framework required before Chromium PiP qualification")
            return
        }
        var server: PiPReturnServer?, port: UInt16 = 0, tab = "", other = ""
        let owner = c!
        func page() -> EngineTab? { owner.engineTab(for: tab) }
        func window() -> NSWindow? { page().flatMap { PiPEngineOverlay.state($0, in: chromium)?["window"] as? NSWindow } }
        func controls() -> PiPControlsView? { page().flatMap { PiPOverlays.shared.controls(for: $0) } }
        func verdict(_ ok: Bool, _ what: String) {
            if !ok { note("parityp16a video state: frame=\(String(describing: window()?.frame)), aspect=\(String(describing: window()?.contentAspectRatio)), minimized=\(controls()?.miniPlayer.state.isMinimized == true)") }
            let w = window() ?? owner.window
            let why = Self.screenLocked ? "locked display" : !w.isOnActiveSpace ? "off active Space"
                : !w.occlusionState.contains(.visible) ? "covered window" : nil
            if let why { note("FAIL-ENV parityp16a video: \(what) (\(why); underlying \(ok))") }
            else { check(ok, "parityp16a video: " + what) }
        }
        func js(_ expression: String) {
            step { done in
                guard let p = page() else { verdict(false, "missing video page"); return done() }
                chromium.devToolsCall("Runtime.evaluate", params: ["expression": expression, "userGesture": true,
                                      "awaitPromise": true, "returnByValue": true], in: p) { _, _ in done() }
            }
        }
        func expect(_ what: String, _ condition: @escaping () -> Bool) {
            step { [self] done in waitUntil(condition, timeout: 8) { verdict(condition(), what); done() } }
        }
        func shape(_ ratio: CGFloat) -> Bool {
            window().map { abs($0.frame.width / max(1, $0.frame.height) / ratio - 1) < 0.02 } == true
        }
        step { done in server = PiPReturnServer(); server?.start { port = $0 ?? 0; done() } }
        run {
            tab = (try? owner.store.openTab(url: "http://127.0.0.1:\(port)/aspect", inSpace: owner.currentSpaceID).id) ?? ""
            other = (try? owner.store.openTab(url: "data:text/html,<title>Notes</title>", inSpace: owner.currentSpaceID).id) ?? ""
            owner.reloadAll(animated: false); owner.show(tab, focus: false)
        }
        expect("aspect fixture loads") { page()?.title == "Aspect" && page()?.isLoading == false }
        js("load('/movie.mp4')")
        js("v.requestPictureInPicture().then(()=>true)")
        step { [self] done in waitUntil({ window()?.isVisible == true }, timeout: 6) { done() } }
        wait(0.6)
        expect("video PiP opens") { window()?.isVisible == true }
        run {
            guard let w = window() else { return }
            let production = w.value(forKey: "aircProductionPiPConfiguration") as? [String: NSNumber]
            let behavior = NSWindow.CollectionBehavior(rawValue: production?["collectionBehavior"]?.uintValue ?? 0)
            verdict(production?["level"]?.intValue == NSWindow.Level.floating.rawValue
                    && behavior.contains(.canJoinAllApplications) && behavior.contains(.fullScreenAuxiliary),
                    "production readback retains floating/fullscreen policy")
            verdict(w.level == .normal && !w.collectionBehavior.contains(.canJoinAllSpaces)
                    && !w.collectionBehavior.contains(.canJoinAllApplications) && !w.collectionBehavior.contains(.fullScreenAuxiliary),
                    "test window uses normal level and own desktop")
            w.setFrame(NSRect(origin: w.frame.origin, size: NSSize(width: 480, height: 270)), display: true)
        }
        expect("resize preserves landscape aspect") { shape(16/9) }
        run { controls()?.miniPlayer.setMinimized(true, animated: false) }
        expect("video collapses to pill") { controls()?.miniPlayer.state.isMinimized == true && window()?.frame.height == 48 }
        js("load('/tall.mp4')")
        run { controls()?.miniPlayer.setMinimized(false, animated: false) }
        expect("new portrait source takes its aspect after pill") { shape(9/16) }
        run { controls()?.hide.action?() }
        // Hidden state is intentionally sampled without a visible-window verdict.
        run { [self] in check(page().map { HiddenMiniPlayers.isHidden($0) } == true && window()?.isVisible == false,
                             "parityp16a video: minus hides presentation") }
        js("load('/movie.mp4')")
        wait(0.6)
        expect("new landscape source restores hidden player with its own aspect") { window()?.isVisible == true && shape(16/9) }
        run {
            controls()?.miniPlayer.setMinimized(true, animated: false)
            controls()?.miniPlayer.setMinimized(false)
        }
        js("load('/tall.mp4')")
        wait(0.6)
        expect("source change during expansion keeps the new aspect") { shape(9/16) }
        run { controls()?.hide.action?() }
        run {
            if let m = MediaLibrary.shared.media, let p = m.sessions[tab] { m.activatePlayer(p) }
        }
        wait(0.6)
        expect("sidebar restores hidden video") { window()?.isVisible == true && page().map { !HiddenMiniPlayers.isHidden($0) } == true }
        run {
            guard let v = controls(), let w = window() else { return }
            // The actual responder method, never posted to the owner's HID queue.
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            guard idle >= 120 else { self.note("IMPOSSIBLE parityp16a video: space key deferred; HID idle below 120 seconds"); return }
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) { v.keyDown(with: e) }
        }
        expect("space responder pauses video") { MediaLibrary.shared.media?.sessions[tab]?.session.playback == .paused }
        run { controls()?.actions.seek(1, true) }
        wait(0.3)
        step { done in page()?.evaluate("v.paused && Math.abs(v.currentTime - 1) < 0.3") { value in
            verdict(value as? Bool == true, "seek reaches paused video"); done()
        } }
        run {
            if let item = controls()?.miniPlayer.contextMenu().items.first(where: { $0.representedObject as? String == "never" }) {
                controls()?.miniPlayer.performMenu(item)
            }
        }
        wait(0.5)
        run {
            verdict(!owner.callWindowAllowed(for: page()?.url), "context menu persists site exclusion")
            owner.show(other, focus: false)
        }
        js("v.play()")
        wait(1)
        run {
            verdict(window() == nil, "excluded site stays inline when leaving tab")
            if let origin = MiniPlayerSite.origin("http://127.0.0.1:\(port)") {
                self.app?.settings.values.pipSites[origin] = nil; owner.applyPictureInPictureSettings(cleared: [origin])
            }
            owner.closeTab(tab); owner.closeTab(other); server?.stop()
        }
        #endif
    }
}

extension SnapshotRunner {
    /// Resolve the page at execution time, after setup, including in the standalone WebKit bundle.
    private func parityP16aSystemVideoScenario() {
        var server: PiPReturnServer?, port: UInt16 = 0, tab = ""
        let owner = c!
        func page() -> WebKitTab? { owner.engineTab(for: tab) as? WebKitTab }
        func verdict(_ ok: Bool, _ message: String) {
            let w = owner.window
            if Self.screenLocked || !w.isOnActiveSpace || !w.occlusionState.contains(.visible) {
                note("FAIL-ENV parityp16a system: \(message) (locked=\(Self.screenLocked), activeSpace=\(w.isOnActiveSpace), visible=\(w.occlusionState.contains(.visible)), underlying=\(ok))")
            } else { check(ok, "parityp16a system: " + message) }
        }
        run { ProtectedMedia.shared.testHosts = ["localhost"]; verdict(PiPAgentProbe.install(), "controller recorder installs") }
        step { done in server = PiPReturnServer(); server?.start { port = $0 ?? 0; done() } }
        run {
            tab = (try? owner.store.openTab(url: "http://localhost:\(port)/aspect", inSpace: owner.currentSpaceID).id) ?? ""
            owner.reloadAll(animated: false); owner.show(tab, focus: false)
        }
        step { [self] done in waitUntil({ page()?.title == "Aspect" }, timeout: 15) { done() } }
        for (source, ratio) in [("/movie.mp4", 16.0/9), ("/tall.mp4", 9.0/16), ("/movie.mp4", 16.0/9)] {
            step { done in
                guard let p = page() else { verdict(false, "missing Safari-engine page"); return done() }
                p.evaluate("load('\(source)'); true") { _ in done() }
            }
            wait(0.5)
            step { done in page()?.requestSystemPictureInPicture { _ in done() } }
            step { [self] done in
                func matches() -> Bool {
                    guard let p = page(), SystemPictureInPicture.isOpen(p),
                          let size = (PiPAgentProbe.current?.value(forKey: "aspectRatio") as? NSValue)?.sizeValue, size.height > 0 else { return false }
                    return abs(size.width / size.height / ratio - 1) < 0.02
                }
                waitUntil(matches, timeout: 8) {
                    let size = (PiPAgentProbe.current?.value(forKey: "aspectRatio") as? NSValue)?.sizeValue
                    verdict(matches(), "source \(source) has native PiP aspect \(String(describing: size)), expected \(ratio)")
                    done()
                }
            }
            // Hide and reopen use the same system path as the sidebar menu; the last source also tests live replacement.
            if source == "/tall.mp4" { continue }
            step { done in page()?.closeSystemPictureInPicture(pause: false, completion: done) }
        }
        step { done in page()?.closeSystemPictureInPicture(pause: true, completion: done) }
        run { owner.closeTab(tab); ProtectedMedia.shared.testHosts = []; server?.stop() }
    }
}
#endif
