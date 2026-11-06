// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    /// No screenshots, HID input or media devices. Each invocation lasts at most 55 seconds.
    /// Native Spaces are intrusive: recheck three minutes' hardware idle immediately before entry.
    func fullscreenExitCheck() {
        let mode = ProcessInfo.processInfo.environment["AIRC_FULLSCREEN_CASE"] ?? "native"
        func permitted() -> Bool {
            if let reason = inputBlocked { skip("fullscreen exit: \(reason)"); return false }
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            guard idle >= 180 else { skip("fullscreen exit: owner idle only \(Int(idle)) s (needs 180)"); return false }
            return true
        }
        // Exercise the exit-phase contract even in daytime suites, without entering a native Space.
        if mode == "native" {
            c.fullScreen.willEnter()
            c.fullScreen.willExit()
            check(c.isFullscreen, "native exit phase: keep fullscreen traffic-light layout until didExit")
            c.fullScreen.didExit()
            check(!c.isFullscreen, "native exit phase: restore windowed state after didExit")
        }
        guard permitted() else { return }
        // An attach point for open -g + lldb; never enabled by the build suite.
        if ProcessInfo.processInfo.environment["AIRC_FULLSCREEN_DEBUG_PAUSE"] == "1" { raise(SIGSTOP) }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if c.window.styleMask.contains(.fullScreen) { c.window.toggleFullScreen(nil) }
            note("FAIL fullscreen exit: exceeded 50 s attempt budget")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.finish() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 50, execute: deadline)
        if mode == "native" {
            for cycle in 1...3 {
                var entered = false
                run { [self] in
                    guard permitted() else { return }
                    entered = true
                    c.window.toggleFullScreen(nil)
                }
                step { [self] done in
                    guard entered else { return done() }
                    waitUntil({ self.c.window.styleMask.contains(.fullScreen) && self.c.isFullscreen }, timeout: 5, then: done)
                }
                wait(1)
                run { [self] in
                    guard entered else { return }
                    check(c.isFullscreen && c.window.styleMask.contains(.fullScreen), "native fullscreen cycle \(cycle): entered")
                    c.fullScreen.exit()
                }
                step { [self] done in
                    guard entered else { return done() }
                    waitUntil({ !self.c.isFullscreen && !self.c.window.styleMask.contains(.fullScreen) }, timeout: 5, then: done)
                }
                wait(0.5)
                run { [self] in
                    guard entered else { return }
                    check(!c.isFullscreen && !c.window.styleMask.contains(.fullScreen), "native fullscreen cycle \(cycle): exited and still alive")
                    check(!c.window.titlebarAccessoryViewControllers.contains { $0 is FullScreenRevealAccessory },
                          "native fullscreen cycle \(cycle): accessory removed after transition")
                }
            }
        } else {
            #if canImport(AircCore)
            htmlFullscreenExitCheck(mode: mode, permitted: permitted)
            #else
            skip("HTML5 fullscreen exit requires Chromium DevTools user gesture")
            #endif
        }
        run { deadline.cancel() }
    }

    #if canImport(AircCore)
    private func htmlFullscreenExitCheck(mode: String, permitted: @escaping () -> Bool) {
        guard let engine = app?.engine as? ChromiumEngine else { skip("HTML5 fullscreen: Chromium unavailable"); return }
        var server: LocalPageServer?
        var page: EngineTab?
        var little: LittleArcController?
        var entered = false
        var originalTab = ""
        let originalSpace = c.currentSpaceID
        var otherSpace = ""
        var otherTab = ""
        let html = """
        <title>Fullscreen fixture</title><div id="box"><button id="leave" onclick="document.exitFullscreen()">Exit</button></div>
        <canvas id="canvas" width="160" height="90"></canvas><video id="video" muted playsinline></video>
        <script>
        const ctx=canvas.getContext('2d');let n=0;
        setInterval(()=>{ctx.fillStyle=`hsl(${n++%360},70%,50%)`;ctx.fillRect(0,0,160,90)},40);
        video.srcObject=canvas.captureStream(25);
        </script>
        """
        step { [self] done in
            server = LocalPageServer(responses: ["/fullscreen": .init(body: html)])
            server?.start { port in
                guard let port else { self.check(false, "fullscreen: loopback fixture starts"); return done() }
                let url = "http://127.0.0.1:\(port)/fullscreen"
                if mode == "little" {
                    little = self.app?.openLittleArc(url: URL(string: url), spaceID: self.c.currentSpaceID)
                    page = little?.page
                } else if let tab = try? self.c.store.openTab(url: url, inSpace: self.c.currentSpaceID, activate: false) {
                    if mode == "split", let second = try? self.c.store.openTab(url: url, inSpace: self.c.currentSpaceID, activate: false) {
                        _ = try? self.c.store.createSplit([tab.id, second.id], inSpace: self.c.currentSpaceID, focused: tab.id)
                    }
                    originalTab = tab.id
                    if mode == "switch" {
                        otherTab = (try? self.c.store.openTab(url: url, inSpace: originalSpace, activate: false))?.id ?? ""
                        otherSpace = (try? self.c.store.createSpace(name: "Fullscreen other", icon: nil, theme: self.c.store.selectedSpace.theme,
                            profileID: self.c.store.defaultProfile.id, after: originalSpace))?.id ?? ""
                    }
                    self.c.reloadAll(animated: false)
                    self.c.show(tab.id, focus: false)
                    page = self.c.engineTab(for: tab.id)
                }
                self.waitUntil({ page?.title == "Fullscreen fixture" && page?.isLoading == false }, timeout: 6, then: done)
            }
        }
        func evaluate(_ expression: String, _ completion: @escaping (Bool) -> Void) {
            guard let page else { return completion(false) }
            engine.devToolsCall("Runtime.evaluate", params: ["expression": expression, "userGesture": true,
                "awaitPromise": true, "returnByValue": true], in: page) { reply, _ in
                completion((reply?["result"] as? [String: Any])?["value"] as? Bool == true)
            }
        }
        for target in ["box", "video"] {
            for exit in (mode == "switch" ? ["tab", "space"] : ["api", "escape", "button"]) {
                step { [self] done in
                    guard permitted() else { entered = false; return done() }
                    evaluate("(async()=>{await video.play();await \(target).requestFullscreen();return document.fullscreenElement===\(target)})()") { ok in
                        entered = ok
                        self.check(ok, "HTML5 \(mode)/\(target)/\(exit): entered")
                        done()
                    }
                }
                wait(0.3)
                step { [self] done in
                    guard entered, let page else { return done() }
                    if exit == "tab" {
                        c.show(otherTab, focus: false)
                        done()
                    } else if exit == "space" {
                        c.switchToSpace(otherSpace, animated: false)
                        done()
                    } else if exit == "escape" {
                        // DevTools dispatch reaches only this renderer, never the owner's HID session.
                        engine.devToolsCall("Input.dispatchKeyEvent", params: ["type": "keyDown", "key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27], in: page) { _, _ in
                            engine.devToolsCall("Input.dispatchKeyEvent", params: ["type": "keyUp", "key": "Escape", "code": "Escape", "windowsVirtualKeyCode": 27], in: page) { _, _ in done() }
                        }
                    } else {
                        evaluate(exit == "button" ? "(leave.click(),true)" : "document.exitFullscreen().then(()=>true)") { _ in done() }
                    }
                }
                wait(0.4)
                step { [self] done in
                    guard entered else { return done() }
                    evaluate("!document.fullscreenElement && !video.paused") { ok in
                        self.check(ok, "HTML5 \(mode)/\(target)/\(exit): exited, video still playing, browser alive")
                        // Cleanup even on failed exit; the next request must start windowed.
                        evaluate("(async()=>{if(document.fullscreenElement)await document.exitFullscreen();return true})()") { _ in
                            if mode == "switch" {
                                self.c.switchToSpace(originalSpace, animated: false)
                                self.c.show(originalTab, focus: false)
                            }
                            done()
                        }
                    }
                }
            }
        }
        run { [self] in
            if let little { little.window.performClose(nil) }
            if let page { engine.closePictureInPicture(page) }
            server?.stop()
        }
    }
    #endif
}
#endif
