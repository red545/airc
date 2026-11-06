// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

#if canImport(AircCore)
/// Part of `--script events` (Chromium): LA-1's mini player. A loopback page plays a video (a canvas stream, no sound,
/// nothing captured) in a Little Arc window:
///   - ⌘W (posted to the window) hides the window and the video goes on in picture in picture: the controller and its
///     page stay, `document.pictureInPictureElement` is the video;
///   - "back to tab" (the engine's activation request, as its picture-in-picture window sends it) brings the window
///     back and closes the picture in picture;
///   - closed again, then the picture in picture closed: the window and its page are gone;
///   - with picture in picture off in Settings, ⌘W closes the window as before.
extension SnapshotRunner {
    func littleArcMiniPlayerCheck() {
        guard let engine = app?.engine as? ChromiumEngine else { return }
        var server: LocalPageServer?
        var base = ""
        var little: LittleArcController?
        let video = """
            <title>video</title><canvas id="c" width="160" height="90"></canvas><video id="v" playsinline></video>
            <script>var c=document.getElementById('c'),x=c.getContext('2d'),n=0;
            setInterval(function(){x.fillStyle='hsl('+(n++*7%360)+',60%,50%)';x.fillRect(0,0,160,90)},33);
            document.getElementById('v').srcObject=c.captureStream(30);</script>
            """
        step { [self] done in
            server = LocalPageServer(responses: ["/video": .init(body: video)])
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                if base.isEmpty { self.check(false, "mini player: the loopback server starts") }
                done()
            }
        }
        func openPlaying(_ name: String) {
            step { [self] done in
                guard let app, !base.isEmpty else { return done() }
                little = app.openLittleArc(url: URL(string: base + "/video"), spaceID: c.currentSpaceID)
                waitUntil({ little?.page?.title == "video" && little?.page?.isLoading == false }, timeout: 8) {
                    guard let p = little?.page else { self.check(false, "mini player (\(name)): the Little Arc page loads"); return done() }
                    engine.devToolsCall("Runtime.evaluate", params: [
                        "expression": "document.getElementById('v').play().then(function(){document.title='playing'})",
                        "userGesture": true, "awaitPromise": true, "returnByValue": true], in: p) { _, _ in
                        self.waitUntil({ little?.page?.title == "playing" }, timeout: 4) {
                            self.check(little?.page?.title == "playing", "mini player (\(name)): the video plays in Little Arc")
                            done()
                        }
                    }
                }
            }
        }
        /// ⌘W as the person presses it, to the Little Arc window; a never-key window can drop it, then its own handler.
        func commandW() {
            step { [self] done in
                guard let l = little else { return done() }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: l.window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                isARepeat: false, keyCode: 13) { NSApp.postEvent(e, atStart: false) }
                }
                waitUntil({ l.isMiniPlayer || !l.window.isVisible }, timeout: 1) {
                    if l.window.isVisible, !l.isMiniPlayer {
                        self.note("mini player: the posted ⌘W didn't arrive (window key \(l.window.isKeyWindow)); its handler instead")
                        _ = l.handleKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: l.window.windowNumber,
                                                         context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false,
                                                         keyCode: 13)!)
                    }
                    done()
                }
            }
        }
        func pictureInPictureElement(_ then: @escaping (Bool) -> Void) {
            guard let p = little?.page else { return then(false) }
            engine.devToolsCall("Runtime.evaluate", params: [
                "expression": "document.pictureInPictureElement===document.getElementById('v')", "returnByValue": true], in: p) { reply, _ in
                then(((reply?["result"] as? [String: Any])?["value"] as? Bool) == true)
            }
        }
        func expectMiniPlayer(_ name: String) {
            step { [self] done in
                waitUntil({ little?.isMiniPlayer == true }, timeout: 5) {
                    pictureInPictureElement { pip in
                        let l = little
                        let kept = l.map { lc in self.app?.littleArcs.contains { $0 === lc } == true } ?? false
                        self.check(l?.isMiniPlayer == true && l?.window.isVisible == false && kept && l?.page?.isClosed == false && pip,
                                   "mini player (\(name)): closing the window hands the video to picture in picture (mini player "
                                   + "\(l?.isMiniPlayer == true), window hidden \(l?.window.isVisible == false), page kept \(kept), "
                                   + "the video in picture in picture \(pip))")
                        done()
                    }
                }
            }
        }

        run { [self] in app?.settings.values.pipAutomatic = true }
        openPlaying("close")
        commandW()
        expectMiniPlayer("⌘W")

        // Back to tab: what the engine sends when its picture-in-picture window's button is pressed.
        run { [self] in if let p = little?.page { engine.pictureInPictureRequestsTab?(p) } }
        step { [self] done in
            waitUntil({ little?.window.isVisible == true && little?.isMiniPlayer == false }, timeout: 3) {
                self.waitUntil({ false }, timeout: 0.6) {
                    pictureInPictureElement { pip in
                        self.check(little?.window.isVisible == true && little?.isMiniPlayer == false && !pip,
                                   "mini player: back to tab brings the Little Arc window back (visible \(little?.window.isVisible == true)) "
                                   + "and closes the picture in picture (still in it \(pip))")
                        done()
                    }
                }
            }
        }

        // Closed again, then its picture in picture closed: the window and the page go.
        run { [self] in
            if let p = little?.page, p.title != "playing" { note("mini player: page title now \(p.title)") }
        }
        step { [self] done in
            guard let p = little?.page else { return done() }
            // Back to tab paused nothing, but make sure it's playing for the second close.
            engine.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('v').play()", "userGesture": true,
                                                             "awaitPromise": true], in: p) { _, _ in done() }
        }
        commandW()
        expectMiniPlayer("⌘W again")
        var page: EngineTab?
        run { page = little?.page; if let p = page { engine.closePictureInPicture(p) } }
        step { [self] done in
            waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 5) {
                self.check(self.app?.littleArcs.isEmpty == true && little?.window.isVisible != true,
                           "mini player: closing the picture in picture closes the Little Arc window and its page "
                           + "(windows left \(self.app?.littleArcs.count ?? -1), page closed \(page?.isClosed ?? true))")
                done()
            }
        }

        // Picture in picture off: ⌘W closes the window as before.
        run { [self] in app?.settings.values.pipAutomatic = false }
        openPlaying("off")
        commandW()
        step { [self] done in
            waitUntil({ self.app?.littleArcs.isEmpty == true }, timeout: 5) {
                self.check(self.app?.littleArcs.isEmpty == true && little?.isMiniPlayer == false,
                           "mini player: with picture in picture off, ⌘W closes the window (windows left \(self.app?.littleArcs.count ?? -1))")
                done()
            }
        }
        run { [self] in
            app?.settings.values.pipAutomatic = true
            server?.stop()
        }
    }
}
#endif
#endif
