// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script pipcontrols` (Chromium): Airc's controls in the engine's picture in picture (SB-55, engine/PIP.md "App
/// overlay"), device-free. A loopback video page with a full Media Session (metadata, position state, play, pause,
/// seek, skip and track handlers) and a Meet-like call page (a canvas `captureStream()` and silent WebAudio over two
/// local peer connections; never getUserMedia). Presses are native mouse events sent to the PiP window itself, through
/// the engine's pointer handling, never to the screen. Screenshots capture only our own PiP window.
extension SnapshotRunner {
    func pipControlsScenario() {
        #if canImport(AircCore)
        guard let chromium = app?.engine as? ChromiumEngine else {
            note("SKIP pipcontrols: the engine's picture in picture is Chromium's (WebKit uses the system's)")
            return
        }
        let x = PiPCheckContext()
        step { [self] done in
            x.server = LocalPageServer(pages: ["/video": PiPCheckPages.video, "/call": PiPCheckPages.call])
            x.server?.start { port in
                x.base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                self.check(!x.base.isEmpty, "pipcontrols: the loopback server starts")
                done()
            }
        }
        run { [self] in
            check(PiPEngineOverlay.available, "pipcontrols: the framework hosts app overlays (setPictureInPictureOverlayProvider:)")
            do {
                let home = c.currentSpaceID
                x.video = try c.store.openTab(url: x.base + "/video", inSpace: home).id
                x.call = try c.store.openTab(url: x.base + "/call", inSpace: home).id
                x.meet = try c.store.openTab(url: x.base + "/call?pip=document", inSpace: home).id
                x.other = try c.store.openTab(url: "data:text/html,<title>Elsewhere</title>", inSpace: home).id
                c.reloadAll(animated: false)
                c.show(x.video, focus: false)
            } catch { check(false, "pipcontrols: setup (\(error))") }
        }
        pipVideo(x, chromium)
        pipCallVideo(x, chromium)
        pipDocument(x, chromium)
        run { [self] in
            NSApp.appearance = nil
            note("pipcontrols: done")
            x.server?.stop()
        }
        #else
        note("SKIP pipcontrols: Chromium only")
        #endif
    }
}

#if canImport(AircCore)
final class PiPCheckContext {
    var server: LocalPageServer?
    var base = ""
    var video = "", call = "", meet = "", other = ""
    var activeBefore = false
}

extension SnapshotRunner {
    // MARK: Helpers

    private func page(_ id: String) -> EngineTab? { c.engineTab(for: id) }

    private func pipState(_ id: String, _ chromium: ChromiumEngine) -> [String: Any]? {
        page(id).flatMap { PiPEngineOverlay.state($0, in: chromium) }
    }

    private func pipWindow(_ id: String, _ chromium: ChromiumEngine) -> NSWindow? { pipState(id, chromium)?["window"] as? NSWindow }

    private func controls(_ id: String) -> PiPControlsView? { page(id).flatMap { PiPOverlays.shared.controls(for: $0) } }

    /// The page's log and state (`state()` in both fixtures).
    private func pageState(_ id: String, _ then: @escaping ([String: Any]) -> Void) {
        guard let p = page(id) else { return then([:]) }
        p.evaluate("JSON.stringify(state())") { v in
            let s = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            then(s)
        }
    }

    /// Runs `js` with a user gesture (play needs one).
    private func gesture(_ id: String, _ js: String, _ chromium: ChromiumEngine, _ done: @escaping () -> Void) {
        guard let p = page(id) else { return done() }
        chromium.devToolsCall("Runtime.evaluate", params: ["expression": js, "userGesture": true, "awaitPromise": true, "returnByValue": true],
                              in: p) { _, _ in done() }
    }

    private func event(_ type: NSEvent.EventType, _ w: NSWindow, _ p: NSPoint, _ t: TimeInterval, _ flags: NSEvent.ModifierFlags = []) {
        // Timestamps in the past: Chromium's DCHECK build checks input latency against them.
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: t, windowNumber: w.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        w.sendEvent(e)
    }

    /// A press at `from` (window points), dragged to `to` in a few steps, then released.
    private func press(_ w: NSWindow, _ from: NSPoint, to: NSPoint? = nil, flags: NSEvent.ModifierFlags = []) {
        let t = ProcessInfo.processInfo.systemUptime - 2
        event(.leftMouseDown, w, from, t, flags)
        if let to {
            // Window coordinates move with the window: aim each step at the screen point, as the window server does.
            let s0 = w.convertPoint(toScreen: from), s1 = w.convertPoint(toScreen: to)
            for (i, f) in [0.25, 0.5, 0.75, 1.0].enumerated() {
                let s = NSPoint(x: s0.x + (s1.x - s0.x) * f, y: s0.y + (s1.y - s0.y) * f)
                event(.leftMouseDragged, w, w.convertPoint(fromScreen: s), t + 0.1 * Double(i + 1), flags)
            }
            event(.leftMouseUp, w, w.convertPoint(fromScreen: s1), t + 0.6, flags)
        } else {
            event(.leftMouseUp, w, from, t + 0.08, flags)
        }
    }

    /// The centre of `v` in its window's coordinates.
    private func centre(_ v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }

    /// Clicks one of the PiP's controls (shown first), then checks the page's log for `expect`.
    private func clickControl(_ x: PiPCheckContext, _ tab: @escaping () -> String, _ chromium: ChromiumEngine, _ name: String,
                              _ button: @escaping (PiPControlsView) -> NSView, expect: @escaping ([String: Any]) -> Bool) {
        step { [self] done in
            let id = tab()
            guard let v = controls(id), let w = v.window else { check(false, "pipcontrols: \(name): no controls"); return done() }
            v.pointerMoved()
            self.whenStill(w) {
                v.pointerMoved()
                let b = button(v)
                let before = w.frame
                self.press(w, self.centre(b))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.pageState(id) { s in
                        // Not dragged: the top-left corner stays (Chromium may still fit the size to the video's).
                        let held = abs(before.minX - w.frame.minX) < 1 && abs(before.maxY - w.frame.maxY) < 1
                        let log = (s["log"] as? [String] ?? []).suffix(3).joined(separator: ", ")
                        self.check(expect(s) && held && NSApp.isActive == x.activeBefore,
                                   "pipcontrols: \(name) (a native click on the PiP) reaches the page without moving the window or activating Airc "
                                   + "(log …\(log), frame \(NSStringFromRect(before)) → \(NSStringFromRect(w.frame)), active \(NSApp.isActive))")
                        done()
                    }
                }
            }
        }
    }

    /// The page's last seek went `by` seconds from where its clock was (within a second).
    private func seeked(_ s: [String: Any], by: Double) -> Bool {
        guard let last = (s["log"] as? [String] ?? []).last(where: { $0.hasPrefix("seekto:") }) else { return false }
        let parts = last.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 && abs(parts[0] - parts[1] - by) < 1
    }

    /// Once the window has held still for 0.35 s (a spring settled; the PiP floats over the owner's screen, so a
    /// press there may have moved it), at most 3 s.
    private func whenStill(_ w: NSWindow, _ then: @escaping () -> Void) {
        let deadline = CACurrentMediaTime() + 3
        var last = w.frame, since = CACurrentMediaTime()
        func poll() {
            let t = CACurrentMediaTime()
            if w.frame != last { last = w.frame; since = t }
            if t - since >= 0.35 || t > deadline { return then() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }

    private func logged(_ s: [String: Any], _ prefix: String) -> Bool {
        (s["log"] as? [String] ?? []).contains { $0.hasPrefix(prefix) }
    }

    private func screenshotPiP(_ tab: @escaping () -> String, _ chromium: ChromiumEngine, _ name: String, dark: Bool) {
        step { [self] done in
            let id = tab()
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            controls(id)?.pointerMoved()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let w = self.pipWindow(id, chromium) { self.captureOwnWindow(w, name: name + (dark ? "-dark" : "-light")) }
                done()
            }
        }
    }

    /// Sizes the PiP window (keeps its top-left) and lets it lay out.
    private func resizePiP(_ tab: @escaping () -> String, _ chromium: ChromiumEngine, to size: NSSize) {
        step { [self] done in
            let id = tab()
            guard let w = pipWindow(id, chromium) else { return done() }
            let f = w.frame, v = w.screen?.visibleFrame.insetBy(dx: 20, dy: 20) ?? .infinite
            // Keeps the top-left, but stays on the screen.
            let x = min(max(f.minX, v.minX), v.maxX - size.width), y = min(max(f.maxY - size.height, v.minY), v.maxY - size.height)
            w.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            // Chromium's compositor draws the new size a few frames later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
        }
    }

    private func openPiP(_ tab: @escaping () -> String, _ chromium: ChromiumEngine, kind: String) {
        step { [self] done in
            let id = tab()
            guard let p = page(id) else { check(false, "pipcontrols: no page for \(kind) PiP"); return done() }
            if kind == "document" {
                // As Meet's automatic entry does: the Media Session's enterpictureinpicture action, which the page
                // answers with its own Document PiP.
                let sent = chromium.performMediaAction("enterpictureinpicture", value: 0, in: p)
                self.note("pipcontrols: enterpictureinpicture sent \(sent)")
            } else {
                chromium.enterPictureInPictureForHost(p) { route, opened in
                    self.note("pipcontrols: host entry \(kind): \(route) \(opened)")
                }
            }
            waitUntil({ (self.pipState(id, chromium)?["kind"] as? String) == kind && self.pipWindow(id, chromium)?.isVisible == true }, timeout: 6) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
            }
        }
    }

    /// A tab just shown: its call's videos start playing (a hidden tab holds them back).
    private func waitForPlaying(_ tab: @escaping () -> String) {
        step { [self] done in
            let id = tab()
            var playing = false
            func poll(_ n: Int) {
                pageState(id) { s in
                    playing = (s["playing"] as? Bool) == true
                    if playing || n > 20 { self.note("pipcontrols: call videos playing \(playing)"); return done() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll(n + 1) }
                }
            }
            poll(0)
        }
    }

    private func closePiP(_ tab: @escaping () -> String, _ chromium: ChromiumEngine) {
        step { [self] done in
            let id = tab()
            if let p = page(id) { chromium.closePictureInPicture(p) }
            waitUntil({ self.pipState(id, chromium) == nil }, timeout: 4, then: done)
        }
    }

    // MARK: Video

    private func pipVideo(_ x: PiPCheckContext, _ chromium: ChromiumEngine) {
        let id = { x.video }
        step { [self] done in waitUntil({ self.page(id())?.title.contains("ready") == true }, timeout: 12) { done() } }
        step { [self] done in gesture(id(), "start()", chromium, done) }
        step { [self] done in
            waitUntil({ MediaLibrary.shared.media?.sessions[id()]?.session.playback == .playing }, timeout: 6) { done() }
        }
        run { [self] in
            let s = MediaLibrary.shared.media?.sessions[id()]?.session
            check(s?.playback == .playing && s?.duration == 600 && ["play", "pause", "seekto", "previoustrack", "nexttrack"].allSatisfy { s?.actions.contains($0) == true },
                  "pipcontrols: the video page's Media Session reaches the app (\(s.map { "\($0.playback) \($0.duration ?? -1) \($0.actions.sorted())" } ?? "none"))")
            x.activeBefore = NSApp.isActive
            note("pipcontrols: Airc active before the PiP checks: \(x.activeBefore)")
        }
        openPiP(id, chromium, kind: "video")
        run { [self] in
            let st = pipState(id(), chromium)
            let v = controls(id())
            check(st?["appOverlay"] is PiPControlsView && (st?["appOverlay"] as AnyObject?) === v,
                  "pipcontrols: the video PiP hosts Airc's controls (\(st.map { String(describing: $0["appOverlay"] ?? "-") } ?? "no PiP"))")
            check((st?["chromeControls"] as? Bool) == false, "pipcontrols: Chromium's own controls, title and scrim are hidden")
            check(v?.controlsVisible == true, "pipcontrols: the controls show as the PiP arrives")
            check(v?.state.clock?.duration == 600 && v?.state.playing == true && v?.state.hasNext == true && v?.state.hasPrevious == true,
                  "pipcontrols: the controls follow the session (playing, 10:00, previous and next)")
            check(NSApp.isActive == x.activeBefore, "pipcontrols: opening the PiP doesn't activate Airc")
        }
        // Shown on arrival, gone after about 2 s of no movement; back on hover; gone again.
        wait(PiPLayout.introHold + 0.8)
        run { [self] in check(controls(id())?.controlsVisible == false && (controls(id())?.content.layer?.opacity ?? 1) == 0,
                              "pipcontrols: the controls fade out after a still moment") }
        run { [self] in controls(id())?.pointerMoved() }
        wait(0.4)
        run { [self] in check(controls(id())?.controlsVisible == true && (controls(id())?.content.layer?.opacity ?? 0) == 1,
                              "pipcontrols: moving over the PiP brings them back") }
        wait(PiPLayout.hideAfter + 0.6)
        run { [self] in check(controls(id())?.controlsVisible == false, "pipcontrols: and they go again \(PiPLayout.hideAfter) s after the pointer stops") }

        // Regular size: every control, then screenshots.
        resizePiP(id, chromium, to: NSSize(width: 480, height: 270))
        run { [self] in
            let v = controls(id())
            check(v?.sizeClass == .regular && v?.skipBack.isHidden == false && v?.back.title == "Back to Tab" && v?.scrubber.showsTimes == true,
                  "pipcontrols: a 480 × 270 PiP is regular: skip buttons, the Back to Tab pill, times (\(v?.sizeClass.rawValue ?? "-"))")
            check(v.map { pipLayoutOK($0) } == true, "pipcontrols: regular layout keeps every control inside the window, clear of the 8 pt resize edge, none overlapping")
        }
        screenshotPiP(id, chromium, "pipcontrols-video-regular", dark: false)
        screenshotPiP(id, chromium, "pipcontrols-video-regular", dark: true)

        clickControl(x, id, chromium, "Pause", { $0.play }, expect: { self.logged($0, "pause") && ($0["paused"] as? Bool) == true })
        step { [self] done in waitUntil({ self.controls(id())?.state.playing == false }, timeout: 2) { done() } }
        run { [self] in check(controls(id())?.play.symbol == "play.fill", "pipcontrols: the button turns into Play") }
        clickControl(x, id, chromium, "Play", { $0.play }, expect: { self.logged($0, "play") && ($0["paused"] as? Bool) == false })
        // Exactly 15 s from where the page's clock is (its log: "seekto:<to>:<where it was>").
        clickControl(x, id, chromium, "Skip ahead 15 s", { $0.skipAhead }, expect: { self.seeked($0, by: 15) })
        clickControl(x, id, chromium, "Skip back 15 s", { $0.skipBack }, expect: { self.seeked($0, by: -15) })
        clickControl(x, id, chromium, "Next track", { $0.next }, expect: { self.logged($0, "nexttrack") })
        clickControl(x, id, chromium, "Previous track", { $0.previous }, expect: { self.logged($0, "previoustrack") })
        step { [self] done in
            guard let v = controls(id()), let w = v.window, let p = page(id()) else { return done() }
            let was = p.isMuted
            v.pointerMoved()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.press(w, self.centre(v.mute))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.check(p.isMuted != was && v.mute.symbol == (p.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"),
                               "pipcontrols: Mute mutes the tab and shows it (\(p.isMuted))")
                    self.press(w, self.centre(v.mute))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.check(p.isMuted == was, "pipcontrols: and unmutes it")
                        done()
                    }
                }
            }
        }
        // The scrubber: a drag from a fifth to half seeks there, paused while it drags and playing on after.
        step { [self] done in
            guard let v = controls(id()), let w = v.window else { return done() }
            v.pointerMoved()
            page(id())?.evaluate("log.length = 0") { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                let s = v.scrubber, y = s.bounds.height - PiPLayout.draggableHeight / 2
                let from = s.convert(NSPoint(x: s.bounds.width * 0.2, y: y), to: nil), to = s.convert(NSPoint(x: s.bounds.width * 0.5, y: y), to: nil)
                let before = w.frame
                self.press(w, from, to: to)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.pageState(id()) { st in
                        let log = st["log"] as? [String] ?? []
                        let seeks = log.filter { $0.hasPrefix("seekto:") }.compactMap { $0.split(separator: ":").dropFirst().first.flatMap { Double($0) } }
                        self.check((seeks.last.map { abs($0 - 300) < 6 } ?? false) && log.first == "pause" && log.last == "play" && NSEqualRects(before, w.frame),
                                   "pipcontrols: dragging the scrubber seeks (to 5:00), paused during the drag, and the window holds still (log \(log))")
                        done()
                    }
                }
            }
        }
        // Background drag over the overlay still snaps (pipwindow), and ⌘ places freely.
        step { [self] done in
            guard let v = controls(id()), let w = v.window, let area = w.screen?.visibleFrame.insetBy(dx: 20, dy: 20) else { return done() }
            v.setControls(visible: false)
            let start = NSPoint(x: 40, y: w.frame.height * 0.5)
            let screenStart = w.convertPoint(toScreen: start)
            // Aim at the middle of the screen's left half, a little above centre: the nearest corner is top-left.
            let target = NSPoint(x: area.minX + area.width * 0.2, y: area.minY + area.height * 0.7)
            self.press(w, start, to: w.convertPoint(fromScreen: NSPoint(x: screenStart.x + target.x - w.frame.minX, y: screenStart.y + target.y - w.frame.minY)))
            self.waitUntil({ abs(w.frame.minX - area.minX) < 2 && abs(w.frame.maxY - area.maxY) < 2 }, timeout: 2) {
                self.check(abs(w.frame.minX - area.minX) < 2 && abs(w.frame.maxY - area.maxY) < 2 && NSApp.isActive == x.activeBefore,
                           "pipcontrols: a background drag over the controls moves the PiP and it springs to the nearest corner (\(w.frame))")
                let free = NSPoint(x: area.minX + 160, y: area.maxY - w.frame.height - 140)
                let s0 = w.convertPoint(toScreen: start)
                self.press(w, start, to: w.convertPoint(fromScreen: NSPoint(x: s0.x + free.x - w.frame.minX, y: s0.y + free.y - w.frame.minY)), flags: .command)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.check(abs(w.frame.minX - free.x) < 2 && abs(w.frame.minY - free.y) < 2, "pipcontrols: with ⌘ it stays where it's dropped (\(w.frame))")
                    done()
                }
            }
        }

        // Compact: fewer, smaller controls.
        resizePiP(id, chromium, to: NSSize(width: 300, height: 169))
        run { [self] in
            let v = controls(id())
            check(v?.sizeClass == .compact && v?.skipBack.isHidden == true && v?.back.title == nil && v?.scrubber.showsTimes == false && v?.play.isHidden == false,
                  "pipcontrols: a 300 × 169 PiP is compact: no skips, Back to Tab as a glyph, no times (\(v?.sizeClass.rawValue ?? "-"))")
            check(v.map { pipLayoutOK($0) } == true, "pipcontrols: compact layout keeps every control inside the window, clear of the edge, none overlapping")
        }
        screenshotPiP(id, chromium, "pipcontrols-video-compact", dark: false)
        screenshotPiP(id, chromium, "pipcontrols-video-compact", dark: true)
        resizePiP(id, chromium, to: NSSize(width: 400, height: 225))

        // Back to Tab: the tab comes forward and the PiP goes; the video plays on.
        step { [self] done in
            c.show(x.other, focus: false)
            guard let v = controls(id()), let w = v.window else { return done() }
            v.pointerMoved()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.press(w, self.centre(v.back))
                self.waitUntil({ self.pipState(id(), chromium) == nil && self.c.shownTabID == id() }, timeout: 3) {
                    self.pageState(id()) { s in
                        self.check(self.pipState(id(), chromium) == nil && self.c.shownTabID == id() && (s["paused"] as? Bool) == false,
                                   "pipcontrols: Back to Tab shows the tab, closes the PiP, and the video plays on (shown \(self.c.shownTabID ?? "-"))")
                        done()
                    }
                }
            }
        }
        // ✕: the PiP goes and the video pauses.
        openPiP(id, chromium, kind: "video")
        step { [self] done in
            guard let v = controls(id()), let w = v.window else { check(false, "pipcontrols: no PiP for ✕"); return done() }
            v.pointerMoved()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.press(w, self.centre(v.close))
                self.waitUntil({ self.pipState(id(), chromium) == nil }, timeout: 3) {
                    self.pageState(id()) { s in
                        self.check(self.pipState(id(), chromium) == nil && (s["paused"] as? Bool) == true,
                                   "pipcontrols: ✕ closes the PiP and pauses the video (log \(s["log"] ?? "-"))")
                        done()
                    }
                }
            }
        }
    }

    /// Every visible control lies inside the window, 8 pt clear of its edge (the engine's resize band), and no two
    /// overlap.
    private func pipLayoutOK(_ v: PiPControlsView) -> Bool {
        let shown: [NSView] = [v.close, v.back, v.mute, v.previous, v.skipBack, v.play, v.skipAhead, v.next, v.mic, v.camera, v.leave]
            .filter { !$0.isHidden }
        let frames = shown.map { $0.convert($0.bounds, to: v) }
        let inside = v.bounds.insetBy(dx: 7.5, dy: 7.5)
        guard frames.allSatisfy({ inside.contains($0) }) else { return false }
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] where a.intersects(b) { return false } }
        let bar = v.scrubber.isHidden ? nil : v.scrubber.convert(v.scrubber.bounds, to: v)
        return bar.map { b in frames.allSatisfy { !$0.intersects(NSRect(x: b.minX, y: b.maxY - PiPLayout.draggableHeight, width: b.width, height: PiPLayout.draggableHeight)) } } ?? true
    }

    // MARK: A call in the video PiP

    private func pipCallVideo(_ x: PiPCheckContext, _ chromium: ChromiumEngine) {
        let id = { x.call }
        run { [self] in c.show(x.call, focus: false) }
        step { [self] done in
            waitUntil({ MediaLibrary.shared.media?.sessions[id()]?.session.isCall == true && self.page(id())?.title.contains("live") == true }, timeout: 10) { done() }
        }
        waitForPlaying(id)
        openPiP(id, chromium, kind: "video")
        run { [self] in
            let v = controls(id())
            check(v?.state.call == true && v?.mic.isHidden == false && v?.camera.isHidden == false && v?.leave.isHidden == false
                  && v?.play.isHidden == true && v?.scrubber.isHidden == true && v?.mute.isHidden == true,
                  "pipcontrols: a call's PiP has the meeting controls (microphone, camera, leave), no playback ones")
        }
        resizePiP(id, chromium, to: NSSize(width: 400, height: 225))
        screenshotPiP(id, chromium, "pipcontrols-call", dark: false)
        screenshotPiP(id, chromium, "pipcontrols-call", dark: true)
        clickControl(x, id, chromium, "Microphone", { $0.mic }, expect: { self.logged($0, "mic:false") })
        step { [self] done in waitUntil({ self.controls(id())?.state.microphoneOn == false }, timeout: 2) { done() } }
        run { [self] in check(controls(id())?.mic.symbol == "mic.slash.fill", "pipcontrols: the microphone shows muted") }
        screenshotPiP(id, chromium, "pipcontrols-call-muted", dark: true)
        clickControl(x, id, chromium, "Camera", { $0.camera }, expect: { self.logged($0, "cam:false") })
        clickControl(x, id, chromium, "Leave", { $0.leave }, expect: { self.logged($0, "hangup") })
        closePiP(id, chromium)
    }

    // MARK: Document PiP (Meet's own window)

    private func pipDocument(_ x: PiPCheckContext, _ chromium: ChromiumEngine) {
        let id = { x.meet }
        func bar() -> PiPTopBarView? { page(id()).flatMap { PiPOverlays.shared.topBar(for: $0) } }
        run { [self] in c.show(x.meet, focus: false) }
        step { [self] done in waitUntil({ self.page(id())?.title.contains("live") == true }, timeout: 10) { done() } }
        waitForPlaying(id)
        openPiP(id, chromium, kind: "document")
        run { [self] in
            let st = pipState(id(), chromium)
            check(st?["appOverlay"] is PiPTopBarView, "pipcontrols: Meet's own Document PiP gets Airc's top bar")
            check(bar()?.barHeight == 34, "pipcontrols: the bar covers Chromium's 34 pt bar exactly (\(bar()?.barHeight ?? -1))")
        }
        step { [self] done in
            pageState(id()) { s in
                self.check((s["doc"] as? Bool) == true, "pipcontrols: the page moved its call into the Document PiP")
                done()
            }
        }
        screenshotPiP(id, chromium, "pipcontrols-meet", dark: false)
        screenshotPiP(id, chromium, "pipcontrols-meet", dark: true)
        // The bar drags the window (⌘: where it's dropped); its background click reaches nothing.
        step { [self] done in
            guard let b = bar(), let w = b.window else { check(false, "pipcontrols: no top bar"); return done() }
            self.whenStill(w) {
            let p = b.convert(NSPoint(x: b.bounds.midX - 30, y: b.barHeight / 2), to: nil)
            let before = w.frame
            self.press(w, p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let s0 = w.convertPoint(toScreen: p)
                self.press(w, p, to: w.convertPoint(fromScreen: NSPoint(x: s0.x - 60, y: s0.y - 40)), flags: .command)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.pageState(id()) { s in
                        self.check(abs(w.frame.minX - (before.minX - 60)) < 2 && abs(w.frame.minY - (before.minY - 40)) < 2 && (s["doc"] as? Bool) == true
                                   && NSApp.isActive == x.activeBefore,
                                   "pipcontrols: the top bar drags the Document PiP; its click closes nothing (\(NSStringFromRect(before)) → "
                                   + "\(NSStringFromRect(w.frame)), doc \(s["doc"] ?? "-"), active \(NSApp.isActive), log \(s["events"] ?? "-"))")
                        done()
                    }
                }
            }
            }
        }
        // Back to Tab: the call's tab, the PiP closes and the call goes on.
        step { [self] done in
            c.show(x.other, focus: false)
            guard let b = bar(), let w = b.window else { return done() }
            self.press(w, self.centre(b.back))
            self.waitUntil({ self.pipState(id(), chromium) == nil && self.c.shownTabID == id() }, timeout: 3) {
                self.pageState(id()) { s in
                    self.check(self.pipState(id(), chromium) == nil && self.c.shownTabID == id() && (s["ended"] as? Bool) == false && (s["doc"] as? Bool) == false,
                               "pipcontrols: Back to Tab in the top bar shows the call's tab, closes the PiP, the call goes on (\(s["events"] ?? "-"))")
                    done()
                }
            }
        }
        openPiP(id, chromium, kind: "document")
        step { [self] done in
            guard let b = bar(), let w = b.window else { check(false, "pipcontrols: no top bar for ✕"); return done() }
            self.press(w, self.centre(b.close))
            self.waitUntil({ self.pipState(id(), chromium) == nil }, timeout: 3) {
                self.pageState(id()) { s in
                    self.check(self.pipState(id(), chromium) == nil && (s["ended"] as? Bool) == false && NSApp.isActive == x.activeBefore,
                               "pipcontrols: ✕ in the top bar closes the PiP; the call goes on in its tab, Airc stays inactive")
                    done()
                }
            }
        }
    }
}

/// The fixtures. Silent: the video's sound and the call's are WebAudio at zero gain.
enum PiPCheckPages {
    static let video = """
    <!doctype html><meta charset="utf-8"><title>PiP video (loading)</title>
    <body style="margin:0;background:#16222e;color:#fff;font:16px system-ui"><video id="v" playsinline loop style="width:100vw"></video><canvas id="c" width="640" height="360" hidden></canvas>
    <script>
    var log = [], v = document.getElementById('v'), ms = navigator.mediaSession, track = 1, pos = 42, posAt = performance.now(), src;
    function meta(){ ms.metadata = new MediaMetadata({title: 'Fixture Film ' + track, artist: 'Airc', album: 'Loopback'}); }
    // The session's clock: where it was set, running while playing.
    function now(){ return ms.playbackState === 'playing' ? Math.min(600, pos + (performance.now() - posAt) / 1000) : pos; }
    function at(p){ pos = Math.max(0, Math.min(600, p)); posAt = performance.now(); ms.setPositionState({duration: 600, playbackRate: 1, position: pos}); }
    // A two-second clip from a canvas and silent WebAudio (no devices), looping; the session says it's ten minutes.
    async function record(){
      var c = document.getElementById('c'), x = c.getContext('2d'), n = 0;
      var t = setInterval(function(){ x.fillStyle = 'hsl(' + (n * 5 % 360) + ',40%,32%)'; x.fillRect(0, 0, 640, 360);
        x.fillStyle = '#fff'; x.font = '600 44px system-ui'; x.fillText('Airc PiP ' + (n++), 40, 200); }, 50);
      var ac = new AudioContext(), o = ac.createOscillator(), g = ac.createGain(), d = ac.createMediaStreamDestination();
      g.gain.value = 0; o.connect(g).connect(d); o.start();
      var s = c.captureStream(20); s.addTrack(d.stream.getAudioTracks()[0]);
      var r = new MediaRecorder(s, {mimeType: 'video/webm;codecs=vp8,opus'}), chunks = [];
      r.ondataavailable = function(e){ chunks.push(e.data); }; r.start();
      await new Promise(function(f){ setTimeout(f, 2000); }); await new Promise(function(f){ r.onstop = f; r.stop(); });
      clearInterval(t); s.getTracks().forEach(function(k){ k.stop(); }); o.stop(); ac.close();
      src = URL.createObjectURL(new Blob(chunks, {type: 'video/webm'}));
    }
    window.start = async function(){ v.src = src; await v.play(); ms.playbackState = 'playing'; at(pos); document.title = 'PiP video (playing)'; return true; };
    meta();
    ms.setActionHandler('play', function(){ log.push('play'); var p = now(); v.play(); ms.playbackState = 'playing'; at(p); });
    ms.setActionHandler('pause', function(){ log.push('pause'); var p = now(); v.pause(); ms.playbackState = 'paused'; at(p); });
    ms.setActionHandler('seekto', function(d){ log.push('seekto:' + d.seekTime.toFixed(2) + ':' + now().toFixed(2)); at(d.seekTime); });
    ms.setActionHandler('seekbackward', function(d){ log.push('seekbackward:' + (d.seekOffset || 0)); at(now() - (d.seekOffset || 10)); });
    ms.setActionHandler('seekforward', function(d){ log.push('seekforward:' + (d.seekOffset || 0)); at(now() + (d.seekOffset || 10)); });
    ms.setActionHandler('previoustrack', function(){ log.push('previoustrack'); track = Math.max(1, track - 1); meta(); });
    ms.setActionHandler('nexttrack', function(){ log.push('nexttrack'); track++; meta(); });
    function state(){ return {log: log, paused: v.paused, track: track, position: now()}; }
    record().then(function(){ document.title = 'PiP video (ready)'; }, function(e){ document.title = 'PiP video (error ' + e.name + ')'; });
    </script>
    """

    /// `?pip=document`: like Meet, the page opens its own Document PiP from the Media Session's enterpictureinpicture
    /// action and moves its call into it; without it, the host's picture in picture takes the call's video.
    static let call = """
    <!doctype html><meta charset="utf-8"><title>PiP call (connecting)</title>
    <style>body{margin:0;background:#193349;color:#fff;font:14px system-ui}#tiles{display:grid;grid-template-columns:1fr 1fr;gap:6px;padding:6px}
    video{width:100%;border-radius:8px;background:#000}#bar{display:flex;gap:8px;padding:8px}button{font:inherit}</style>
    <div id="tiles"><video id="v" autoplay playsinline></video><video id="me" autoplay muted playsinline></video>
    <div id="bar"><button id="mute">Mute</button><button id="leave">Leave</button></div></div><audio id="r" loop></audio>
    <script>
    var log = [], events = log, stream, a, b, mic = true, cam = true, ended = false, pipWin = null;
    var documentPiP = new URLSearchParams(location.search).get('pip') === 'document', tiles = document.getElementById('tiles');
    function synthetic(){
      var c = document.createElement('canvas'); c.width = 320; c.height = 180; var x = c.getContext('2d'), n = 0;
      setInterval(function(){ x.fillStyle = 'hsl(' + (200 + n++ % 60) + ',40%,34%)'; x.fillRect(0, 0, 320, 180);
        x.fillStyle = '#fff'; x.font = '600 18px system-ui'; x.fillText('Airc call ' + n, 18, 96); }, 66);
      var ac = new AudioContext(), o = ac.createOscillator(), g = ac.createGain(), d = ac.createMediaStreamDestination();
      g.gain.value = 0; o.connect(g); g.connect(d); o.start();
      var s = c.captureStream(15); d.stream.getAudioTracks().forEach(function(t){ s.addTrack(t); }); return s;
    }
    // The far end's audio, as a call plays it: a generated silent WAV (a playing element makes the session active).
    function silentWav(){
      var n = 8000, buf = new ArrayBuffer(44 + n * 2), d = new DataView(buf), w = function(o, s){ for (var i = 0; i < s.length; i++) d.setUint8(o + i, s.charCodeAt(i)); };
      w(0, 'RIFF'); d.setUint32(4, 36 + n * 2, true); w(8, 'WAVEfmt '); d.setUint32(16, 16, true); d.setUint16(20, 1, true); d.setUint16(22, 1, true);
      d.setUint32(24, 8000, true); d.setUint32(28, 16000, true); d.setUint16(32, 2, true); d.setUint16(34, 16, true); w(36, 'data'); d.setUint32(40, n * 2, true);
      return URL.createObjectURL(new Blob([buf], {type: 'audio/wav'}));
    }
    function report(){ try { navigator.mediaSession.setMicrophoneActive(mic); navigator.mediaSession.setCameraActive(cam); } catch (e) {} }
    // Held from the start: the tiles move into the Document PiP, out of this document.
    var remote = document.getElementById('v'), local = document.getElementById('me');
    function state(){ var v = remote, me = local;
      return {log: log, events: log.slice(-6), mic: mic, cam: cam, ended: ended, doc: !!pipWin && !pipWin.closed,
      playing: !v.paused && v.readyState > 2 && !me.paused && me.readyState > 2,
      peers: [a && a.connectionState, b && b.connectionState]}; }
    async function start(){
      stream = synthetic();
      a = new RTCPeerConnection(); b = new RTCPeerConnection();
      a.onicecandidate = function(e){ e.candidate && b.addIceCandidate(e.candidate); };
      b.onicecandidate = function(e){ e.candidate && a.addIceCandidate(e.candidate); };
      b.ontrack = function(e){ document.getElementById('v').srcObject = e.streams[0]; };
      document.getElementById('me').srcObject = stream;
      stream.getTracks().forEach(function(t){ a.addTrack(t, stream); });
      await a.setLocalDescription(await a.createOffer()); await b.setRemoteDescription(a.localDescription);
      await b.setLocalDescription(await b.createAnswer()); await a.setRemoteDescription(b.localDescription);
      var ms = navigator.mediaSession;
      ms.setActionHandler('togglemicrophone', function(){ mic = !mic; stream.getAudioTracks().forEach(function(t){ t.enabled = mic; }); log.push('mic:' + mic); report(); });
      ms.setActionHandler('togglecamera', function(){ cam = !cam; stream.getVideoTracks().forEach(function(t){ t.enabled = cam; }); log.push('cam:' + cam); report(); });
      ms.setActionHandler('hangup', function(){
        ended = true; log.push('hangup'); stream.getTracks().forEach(function(t){ t.stop(); }); a.close(); b.close(); document.getElementById('r').pause();
        ['togglemicrophone', 'togglecamera', 'hangup'].forEach(function(k){ try { ms.setActionHandler(k, null); } catch (e) {} });
      });
      if (documentPiP) ms.setActionHandler('enterpictureinpicture', async function(){
        log.push('enterpictureinpicture');
        try {
          pipWin = await documentPictureInPicture.requestWindow({width: 420, height: 300});
          pipWin.document.head.append(document.querySelector('style').cloneNode(true));
          pipWin.document.body.style.cssText = 'margin:0;background:#193349;color:#fff;font:14px system-ui';
          pipWin.document.body.append(tiles); log.push('document-enter');
          pipWin.addEventListener('pagehide', function(){ document.body.prepend(tiles); log.push('document-exit'); }, {once: true});
        } catch (e) { log.push('pip-error:' + e.name); }
      });
      document.getElementById('mute').onclick = function(){ navigator.mediaSession && log.push('page-mute'); };
      var r = document.getElementById('r'); r.src = silentWav(); r.play().catch(function(e){ log.push('audio:' + e.name); });
      report(); log.push('started'); document.title = 'PiP call (live)';
    }
    start().catch(function(e){ log.push('error:' + e.name); document.title = 'PiP call (error ' + e.name + ')'; });
    </script>
    """
}
#endif
#endif
