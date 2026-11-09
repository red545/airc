// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    /// Both engines, loopback and synthetic tracks only. Checks the actual call window and its menu targets.
    func media2Scenario() {
        run { [self] in
            var session = EngineMediaSession()
            session.capture.microphone = true; session.capture.camera = true
            let fallback = PiPOverlays.state(session, muted: false, at: 0)
            check(fallback.hasMicrophone && fallback.microphoneOn && fallback.hasCamera && fallback.cameraOn,
                  "media2: live capture without reported track state never shows as off")
            session.microphoneActive = false; session.cameraActive = false
            let explicit = PiPOverlays.state(session, muted: false, at: 0)
            check(!explicit.microphoneOn && !explicit.cameraOn, "media2: explicit track state wins over capture")
        }
        var server: MediaLibServer?
        var base = "", call = "", other = ""
        let calls = MediaLibrary.shared.calls
        var expandedFrame = NSRect.zero
        func controls() -> PiPControlsView? { (calls.window as? CallPanel)?.view.controls }
        func menu(_ index: Int) {
            guard let presentation = controls()?.miniPlayer else { return }
            presentation.performMenu(presentation.contextMenu().item(at: index)!)
        }
        step { done in
            server = MediaLibServer()
            server?.start { port in base = port.map { "http://127.0.0.1:\($0)" } ?? ""; done() }
        }
        run { [self] in
            CallWindowController.followsWindowVisibility = false
            do {
                call = try c.store.openTab(url: base + "/call", inSpace: c.currentSpaceID).id
                other = try c.store.openTab(url: "data:text/html,<title>Notes</title>", inSpace: c.currentSpaceID).id
                c.reloadAll(animated: false)
                c.show(call, focus: false)
            } catch { check(false, "media2: setup \(error)") }
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: call)?.title.contains("(live)") == true }, timeout: 15) { done() } }
        run { [self] in c.show(other, focus: false) }
        step { [self] done in waitUntil({ calls.isShowing }, timeout: 5) { done() } }
        run { [self] in
            check(calls.isShowing, "media2: synthetic call opens on leaving tab")
            if let idle = c.engineTab(for: other), let media = MediaLibrary.shared.media {
                let count = media.retainedTrackCount
                media.trackStateChanged(idle, json: "{\"mic\":null,\"cam\":null}")
                check(media.retainedTrackCount == count, "media2: untracked pages cannot retain track state")
            }
            if let v = controls() {
                check(!v.miniPlayer.handlesPointer(at: v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)), "media2: page center keeps its context menu and responder")
                v.flashControls()
                check(v.miniPlayer.handlesPointer(at: v.close.convert(NSPoint(x: 5, y: 5), to: nil)), "media2: chrome owns its context menu")
            }
            if let v = controls(), let w = v.window {
                expandedFrame = w.frame
                w.makeFirstResponder(v)
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { v.keyDown(with: event) }
            }
        }
        wait(0.8)
        run { [self] in
            if let v = controls() {
                check(v.hitTest(v.convert(NSPoint(x: 2, y: 2), to: v.superview)) == nil,
                      "media2: collapsed pill margin remains draggable")
            }
            check(controls()?.miniPlayer.state.isMinimized == true && (calls.window?.frame.height ?? 999) < 60,
                  "media2: minimized pill is 48pt high")
            if let v = controls(), let w = v.window {
                v.miniPlayer.setMinimized(false)
                v.miniPlayer.setMinimized(true)
                v.miniPlayer.setMinimized(false, animated: false)
                check(w.minSize.height > 48, "media2: interrupted expand preserves original minimum size")
            }
        }
        wait(0.8)
        run { [self] in
            check(controls()?.miniPlayer.state.isMinimized == false && calls.window?.frame == expandedFrame,
                  "media2: expand restores window (expected \(expandedFrame), got \(String(describing: calls.window?.frame)))")
            check(controls()?.miniPlayer.contextMenu().items.count == 5, "media2: all five context menu actions")
            if let v = controls() {
                v.canSuppressSite = false
                check(!v.miniPlayer.contextMenu().items.contains { $0.representedObject as? String == "never" }, "media2: private menu omits persistent site suppression")
                v.canSuppressSite = true
            }
            menu(1)
            check(calls.page?.isMuted == true, "media2: menu mute")
            menu(1)
            check(calls.page?.isMuted == false, "media2: menu unmute")
            controls()?.mic.action?()
            controls()?.camera.action?()
        }
        wait(0.5)
        step { [self] done in
            calls.page?.evaluate("JSON.stringify(state())") { v in
                let d = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let tracks = d?["tracks"] as? [[String: Any]] ?? []
                self.check(tracks.count == 2 && tracks.allSatisfy { $0["enabled"] as? Bool == false }, "media2: page handlers disable synthetic tracks")
                self.check(controls()?.state.microphoneOn == false && controls()?.state.cameraOn == false, "media2: controls report track state")
                done()
            }
            if calls.page == nil { check(false, "media2: missing call page"); done() }
        }
        // Change tracks without Media Session reporting: the outgoing-track observer must update the state.
        run { calls.page?.evaluate("stream.getTracks().forEach(t => t.enabled = true)", completion: nil) }
        wait(0.5)
        run { [self] in
            check(controls()?.state.microphoneOn == true && controls()?.state.cameraOn == true, "media2: track changes without session reporting")
            calls.page?.evaluate("navigator.mediaSession.setActionHandler('togglemicrophone', null)", completion: nil)
        }
        wait(0.5)
        run { [self] in
            check(controls()?.state.hasMicrophone == true && controls()?.state.canToggleMicrophone == false
                  && controls()?.mic.label.contains("control in tab") == true, "media2: unsupported provider control is explicit read-only state")
            controls()?.mic.action?()
            menu(0)
        }
        wait(0.5)
        run { [self] in
            check(!calls.isShowing && c.shownTabID == call, "media2: Back to Tab")
            c.show(other, focus: false)
        }
        step { [self] done in waitUntil({ calls.isShowing }, timeout: 4) { done() } }
        run { controls()?.hide.action?() }
        step { [self] done in
            guard let page = c.engineTab(for: call) else { check(false, "media2: hidden call still has a page"); return done() }
            page.evaluate("Array.from(document.querySelectorAll('audio,video')).some(v => !v.paused)") { value in
                self.check(!calls.isShowing && value as? Bool == true, "media2: minus hides the call window and playback continues")
                if let media = MediaLibrary.shared.media, let player = media.sessions[call] { media.activatePlayer(player) }
                self.check(calls.isShowing && self.c.shownTabID == other, "media2: tray row restores hidden call without changing tabs")
                done()
            }
        }
        run { menu(4) }
        wait(0.5)
        run { [self] in
            check(!calls.isShowing && !c.callWindowAllowed(for: URL(string: base + "/call")), "media2: Don't Show persists the site exception")
            let saved = AppSettings(directory: AppPaths.dataDirectory)
            check(MiniPlayerSite.origin(base).map { saved.values.pipSites[$0] == false } == true,
                  "media2: site suppression survives settings reload")
            c.show(call, focus: false)
            c.show(other, focus: false)
        }
        wait(0.5)
        run { [self] in
            check(!calls.isShowing, "media2: suppressed site stays closed")
            if let origin = MiniPlayerSite.origin(base) { app?.settings.values.pipSites[origin] = nil; c.applyPictureInPictureSettings(cleared: [origin]) }
            c.show(call, focus: false)
            c.show(other, focus: false)
        }
        step { [self] done in waitUntil({ calls.isShowing }, timeout: 4) { done() } }
        run { menu(3) }
        wait(0.5)
        run { [self] in
            check(!calls.isShowing, "media2: Close dismisses")
            c.engineTab(for: call)?.evaluate("Array.from(document.querySelectorAll('audio,video')).some(v => !v.paused)") { value in
                self.check(value as? Bool == true, "media2: Close keeps call playback running")
            }
            c.engineTab(for: call)?.evaluate("document.querySelectorAll('audio,video').forEach(v => v.play().catch(()=>{}))", completion: nil)
            c.show(call, focus: false)
            c.show(other, focus: false)
        }
        step { [self] done in waitUntil({ calls.isShowing }, timeout: 4) { done() } }
        run { menu(2) }
        wait(1)
        step { [self] done in
            guard let page = c.engineTab(for: call) else { check(false, "media2: no page for system PiP"); return done() }
            page.evaluate("!!document.pictureInPictureElement || Array.from(document.querySelectorAll('video')).some(v => v.webkitPresentationMode === 'picture-in-picture')") { value in
                self.check(value as? Bool == true, "media2: Picture in Picture menu opens system PiP")
                page.evaluate("if(document.pictureInPictureElement) document.exitPictureInPicture(); document.querySelectorAll('video').forEach(v => { if(v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline'); })", completion: nil)
                done()
            }
        }
        wait(0.5)
        run { [self] in c.show(call, focus: false); c.show(other, focus: false) }
        step { [self] done in waitUntil({ calls.isShowing }, timeout: 4) { done() } }
        run { controls()?.leave.action?() }
        step { [self] done in waitUntil({ !calls.isShowing }, timeout: 4) { done() } }
        run { [self] in
            check(!calls.isShowing, "media2: Leave ends call")
            server?.stop()
            note("media2: done")
        }
    }
}
#endif
