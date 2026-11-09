// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AVFoundation
import Network
import UniformTypeIdentifiers
import WebKit

// `--script pipreturn` (both engines; the Chromium build lists localhost as a Safari-engine service itself):
//
// 1. A Spotify-like player reaches the media tray. As Spotify's public web player bundle does it: its media element
//    comes from document.createElement and never enters the document, plays MediaSource buffers (AAC in fragmented
//    MP4), runs through Web Audio, starts from the page's own Play button, and only then sets the Media Session
//    (metadata, playback state, position, handlers). Its Canvas is a muted looping video beside it, which is
//    decoration: no picture in picture for it, automatic or asked for.
// 2. The system picture in picture window's return button for a Safari-engine video: WebKit's PIPViewController lives
//    in this process (the window itself is PIPAgent's), and the check calls its delegate as the button does
//    (pipShouldClose:). The tab comes back (hidden in its window, in another Space, its window behind another), the
//    video goes back inline and plays on. Also ✕ (pipActionStop: pauses, as Arc's close) and the tray's Hide (Arc's –:
//    the window goes, playback goes on).
// 3. The Mini Player's corner has Arc's ✕ and – only.
//
// Loopback pages, generated silent media, no accounts, devices, focus changes, HID events or screen capture.

extension SnapshotRunner {
    func pipReturnScenario() {
        var server: PiPReturnServer?, port: UInt16 = 0
        var player = "", video = "", other = "", spaced = "", firstSpace = "", secondSpace = "", frontSpace = ""
        var second: WindowController?
        // The browser window this check started in (app.controller follows the window opened last).
        var main: WindowController?
        var c: WindowController! { main ?? self.c }
        var media: MediaCenter? { MediaLibrary.shared.media }
        func page(_ id: String) -> WebKitTab? { c.engineTab(for: id) as? WebKitTab }
        /// HID idle, Space and occlusion. None of these cases posts input or uses the clipboard, so they run while the
        /// owner works; a case whose window is covered or off the active Space is FAIL-ENV, whatever it did (lead,
        /// 2026-11-07). Case c covers the window with the check's own second window on purpose.
        func environment() -> (problem: String?, summary: String) {
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            guard let w = c?.window else { return (nil, "no window") }
            let order = NSApp.orderedWindows
            let ours = second.map { s in s.window.isVisible && (order.firstIndex(of: s.window) ?? .max) < (order.firstIndex(of: w) ?? .max) } ?? false
            let visible = w.occlusionState.contains(.visible)
            let summary = String(format: "HID idle %.0f s, on the active Space: %@, occlusion: %@", idle, w.isOnActiveSpace ? "yes" : "no",
                                 visible ? "visible" : ours ? "covered by the check's own window" : "covered")
            let problem = Self.screenLocked ? "the screen is locked" : !w.isOnActiveSpace ? "the window isn't on the active Space"
                : !visible && !ours ? "the window is covered by another app's window" : nil
            return (problem, summary)
        }
        var caseName = "setup", caseProblem: String?
        func sample() { if caseProblem == nil, let p = environment().problem { caseProblem = p } }
        func verdict(_ ok: Bool, _ what: String) {
            sample()
            if let p = caseProblem { note("FAIL-ENV \(what) (\(p) during case \(caseName); it \(ok ? "passed" : "failed"); \(environment().summary))") }
            else { check(ok, what) }
        }
        func beginCase(_ name: String) {
            run { [self] in caseName = name; caseProblem = nil; note("pipreturn: case \(name): \(environment().summary)") }
        }
        func endCase() { run { [self] in sample(); note("pipreturn: case \(caseName) done: \(environment().summary)") } }
        func value(_ id: @escaping () -> String, _ js: String, _ then: @escaping (Any?) -> Void) {
            step { done in
                guard let p = page(id()) else { verdict(false, "pipreturn: \(js.prefix(40)): no Safari-engine page"); return done() }
                p.evaluate(js) { v in then(v); done() }
            }
        }
        func expect(_ what: String, timeout: Double = 8, _ ok: @escaping () -> Bool, _ detail: @escaping () -> String = { "" }) {
            step { [self] done in
                waitUntil({ sample(); return ok() }, timeout: timeout) {
                    verdict(ok(), "pipreturn: \(what)\(detail().isEmpty ? "" : " (\(detail()))")"); done()
                }
            }
        }
        /// Polls a page expression until it's true (it reports what it saw).
        func expectPage(_ what: String, _ id: @escaping () -> String, _ js: String, timeout: Double = 8) {
            step { done in
                let started = Date()
                func poll() {
                    sample()
                    guard let p = page(id()) else { verdict(false, "pipreturn: \(what) (no page)"); return done() }
                    p.evaluate("JSON.stringify([!!(\(js)), \(PiPReturnServer.state)])") { v in
                        let text = v as? String ?? "?"
                        if text.hasPrefix("[true") { verdict(true, "pipreturn: \(what)"); return done() }
                        guard Date().timeIntervalSince(started) > timeout else {
                            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
                        }
                        verdict(false, "pipreturn: \(what) (page \(text))")
                        done()
                    }
                }
                poll()
            }
        }

        // pipreturn-tray: 1 and f; pipreturn-return: 2 and 3 (each well inside the runner's four minutes); pipreturn: both;
        // pipreturn-aspect: 4.
        let tray = ["pipreturn", "pipreturn-tray"].contains(script), returns = ["pipreturn", "pipreturn-return"].contains(script)
        let aspect = script == "pipreturn-aspect"
        run { [self] in
            main = self.c
            ProtectedMedia.shared.testHosts = ["localhost"]
            note("pipreturn: WebKit's picture in picture controller recorder \(PiPAgentProbe.install() ? "installed" : "unavailable")")
            firstSpace = c.currentSpaceID
        }
        step { [self] done in
            let s = PiPReturnServer()
            server = s
            s.start { p in
                port = p ?? 0
                if p == nil { self.check(false, "pipreturn: fixture server and media (\(s.problem))") }
                done()
            }
        }

        if tray {
            // MARK: 1. A Spotify-like player reaches the tray
            beginCase("Spotify-like tray")

            run { [self] in
                guard port != 0 else { return }
                do {
                    player = try c.store.openTab(url: "http://localhost:\(port)/player", inSpace: firstSpace).id
                    other = try c.store.openTab(url: "data:text/html,<title>Notes</title><p>Notes", inSpace: firstSpace).id
                    c.reloadAll(animated: false); c.show(player, focus: false)
                } catch { check(false, "pipreturn: setup \(error)") }
            }
            expect("the player is a Safari-engine page", timeout: 15, { page(player)?.isLoading == false && page(player)?.title == "Player" })
            expectPage("the player's MediaSource buffers are ready", { player }, "window.fixtureReady === 'ready'", timeout: 15)
            // The page's own button starts it (a person's click: WebKit runs this as a user gesture).
            value({ player }, "document.getElementById('play').click(); true") { _ in }
            expectPage("its Play button starts the detached MediaSource audio", { player },
                       "window.playResult === 'playing' && !audio.paused && audio.currentTime > 0")
            value({ player }, "JSON.stringify({connected: audio.isConnected, inDocument: document.querySelectorAll('audio').length, blob: audio.src.slice(0, 5), info: info})") { [self] v in
                let s = v as? String ?? ""
                note("pipreturn: player element \(s)")
                verdict(s.contains("\"connected\":false") && s.contains("\"inDocument\":0") && s.contains("\"blob\":\"blob:\""),
                      "pipreturn: the audio element never enters the document and plays a MediaSource (\(s))")
            }
            expect("the Media Session set after play reaches the session", {
                media?.sessions[player].map { $0.session.playback == .playing && $0.session.title == "Loopback Track 1" } == true
            }, { "\(media?.sessions[player].map { "\($0.session.playback) \($0.session.title)" } ?? "no session")" })
            run { [self] in c.show(other, focus: false) }
            expect("leaving the tab puts the player in the tray", {
                media?.players.contains { $0.tabID == player && $0.title == "Loopback Track 1" && $0.subtitle == "Fixture Artist" } == true
            }, { "players: \(media?.players.map { "\($0.title) — \($0.subtitle)" } ?? [])" })
            run { [self] in
                let p = media?.sessions[player]
                verdict(p?.session.artwork.first?.hasSuffix("/art.png") == true, "pipreturn: tray artwork from the Media Session")
                verdict(abs((p?.session.duration ?? 0) - Double(PiPReturnServer.trackSeconds)) < 1.5 && p?.session.actions.isSuperset(of: ["nexttrack", "previoustrack", "seekto"]) == true,
                      "pipreturn: the page's position state and handlers (\(p?.session.duration ?? -1), \(p?.session.actions.sorted() ?? []))")
                verdict(page(player)?.isAudible == true, "pipreturn: the detached element makes the tab audible")
                if let p { media?.togglePlayback(p) }
            }
            expectPage("the tray's pause reaches the page's handler", { player }, "audio.paused && navigator.mediaSession.playbackState === 'paused'")
            run { if let p = media?.sessions[player] { media?.togglePlayback(p) } }
            expectPage("the tray's play resumes it", { player }, "!audio.paused")
            run { if let p = media?.sessions[player] { media?.perform("seekto", p, value: 31.5) } }
            expectPage("the tray's seek reaches the page's handler", { player }, "Math.abs(audio.currentTime - 31.5) < 2")
            expectPage("the song plays on after the seek", { player }, "audio.currentTime > 31.9 && !audio.seeking", timeout: 5)
            run { if let p = media?.sessions[player] { media?.perform("nexttrack", p) } }
            expect("next track's metadata reaches the tray", { media?.players.first { $0.tabID == player }?.title == "Loopback Track 2" },
                   { media?.players.first { $0.tabID == player }?.title ?? "gone" })
            // The Canvas: playing and muted beside the music, so it's decoration.
            expectPage("the Canvas loop plays muted in the page", { player }, "canvasVideo.muted && !canvasVideo.paused && canvasVideo.readyState > 2")
            step { [self] done in
                guard let p = page(player) else { return done() }
                automaticPictureInPicture(p) { automatic in
                    p.requestSystemPictureInPicture { asked in
                        verdict(automatic == "none" && asked == "none",
                                   "pipreturn: the muted Canvas beside the music isn't picture in picture (automatic \(automatic), asked \(asked))")
                        done()
                    }
                }
            }
            wait(0.5)
            expectPage("no picture in picture opened for the music page", { player }, "!document.pictureInPictureElement && canvasVideo.webkitPresentationMode === 'inline'")
            #if canImport(AircCore)
            run { [self] in
                if let p = page(player) {
                    note("pipreturn: leaving the player decided \(HybridTesting.autoPictureInPicture.last { $0.page == ObjectIdentifier(p) }?.result ?? "nothing (WebKit build)")")
                }
            }
            #endif
            endCase()

            // MARK: 1b. The owner's sequence: the song plays, the tab is left, its Canvas goes to picture in picture and is
            // closed. The row's clock is the song's all along, never the loop's.
            beginCase("clock after Canvas picture in picture")
            func clockMatches(_ when: String) {
                step { done in
                    guard let p = page(player) else { verdict(false, "pipreturn: clock \(when): no page"); return done() }
                    p.evaluate("JSON.stringify([audio.duration, audio.currentTime, canvasVideo.duration, canvasVideo.currentTime].map(function(x){ return isFinite(x) ? x : -1; }))") { v in
                        let a = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Double] } ?? []
                        let row = media?.sessions[player]
                        let d = row?.session.duration ?? -1, t = row?.playbackPosition ?? -1
                        let ok = a.count == 4 && abs(d - a[0]) < 0.5 && abs(t - a[1]) < 1.5
                        verdict(ok, String(format: "pipreturn: clock %@: the row has the song's %.1f s at %.1f s (row %.1f s at %.1f s; Canvas %.1f s at %.1f s)",
                                           when, a.first ?? -1, a.count > 1 ? a[1] : -1, d, t, a.count > 2 ? a[2] : -1, a.count > 3 ? a[3] : -1))
                        done()
                    }
                }
            }
            clockMatches("with the tab left")
            value({ player }, "canvasVideo.requestPictureInPicture().then(function(){ window.canvasPiP = 'in'; }, function(e){ window.canvasPiP = 'refused ' + e.name; }); true") { _ in }
            expectPage("the Canvas goes to the system picture in picture", { player }, "window.canvasPiP === 'in' && document.pictureInPictureElement === canvasVideo")
            clockMatches("with the Canvas in picture in picture")
            step { done in page(player)?.closeSystemPictureInPicture(pause: false) { done() } ?? done() }
            expectPage("it closes and the Canvas loops on with the music", { player },
                       "!document.pictureInPictureElement && !canvasVideo.paused && !audio.paused", timeout: 10)
            wait(1)
            clockMatches("after the picture in picture closed")
            wait(3)
            clockMatches("3 s later")
            run { if let p = media?.sessions[player] { media?.perform("nexttrack", p) } }
            wait(0.5)
            clockMatches("on the next track")
            // A page that sets its position state wins over every element, until it clears it.
            value({ player }, "navigator.mediaSession.setPositionState({duration: 200, position: 50}); true") { _ in }
            expect("the page's position state wins", { media?.sessions[player]?.session.duration == 200 },
                   { "\(media?.sessions[player]?.session.duration ?? -1)" })
            value({ player }, "navigator.mediaSession.setPositionState(null); true") { _ in }
            wait(0.3)
            clockMatches("after the page cleared its position state")
            run { if let p = media?.sessions[player] { media?.perform("pause", p) } }

        }

        // MARK: 2. The system window's return button
        endCase()
        beginCase("video page")

        run { [self] in
            guard port != 0 else { return }
            do {
                video = try c.store.openTab(url: "http://localhost:\(port)/video", inSpace: firstSpace).id
                if other.isEmpty { other = try c.store.openTab(url: "data:text/html,<title>Notes</title><p>Notes", inSpace: firstSpace).id }
                c.reloadAll(animated: false); c.show(video, focus: false)
            } catch { check(false, "pipreturn: video setup \(error)") }
        }
        expect("the video page loads in the Safari engine", timeout: 15, { page(video)?.isLoading == false && page(video)?.title == "Video" })
        expectPage("the video can play", { video }, "v.readyState > 2", timeout: 10)
        /// Leaves `tab` (shows `away`), opens the system picture in picture for its playing video and waits for it.
        func openPictureInPicture(_ name: String, _ tab: @escaping () -> String, away: @escaping () -> Void) {
            value(tab, "v.play(); true") { _ in }
            expectPage("\(name): the video plays", tab, "!v.paused && v.currentTime > 0")
            run { away() }
            wait(0.4)
            step { [self] done in
                guard let p = page(tab()) else { return done() }
                p.requestSystemPictureInPicture { r in self.note("pipreturn: \(name): picture in picture asked: \(r)"); done() }
            }
            expectPage("\(name): the video is in the system picture in picture", tab,
                       "document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture'")
            expect("\(name): WebKit's controller and the open state are known", {
                page(tab()).map(systemPictureInPictureOpen) == true && PiPAgentProbe.current != nil
            }, { "open \(page(tab()).map(systemPictureInPictureOpen) == true), controller \(PiPAgentProbe.current != nil)" })
        }
        /// The return button: WebKit's delegate answers it (NO: WebKit returns the video itself, once the page shows).
        var requestsBefore = 0
        func pressReturn(_ name: String, _ tab: @escaping () -> String) {
            run { [self] in
                requestsBefore = page(tab()).map(returnRequestCount) ?? 0
                let answer = PiPAgentProbe.current.flatMap { PiPAgentProbe.shouldClose($0) }
                note("pipreturn: \(name): return button (pipShouldClose:) answered \(answer.map { "\($0)" } ?? "nothing")")
            }
        }
        func returned(_ name: String, _ tab: @escaping () -> String, window: @escaping () -> WindowController?,
                      space: @escaping () -> String, tray: Bool = true) {
            expect("\(name): WebKit asks Airc for the tab", { (page(tab()).map(returnRequestCount) ?? 0) > requestsBefore })
            expect("\(name): the tab is selected in its Space and window", {
                window()?.shownTabID == tab() && window()?.currentSpaceID == space()
            }, { "shown \(window()?.shownTabID == tab()), space \(window()?.currentSpaceID == space())" })
            expectPage("\(name): the video is back in the page and plays on", tab,
                       "!document.pictureInPictureElement && v.webkitPresentationMode === 'inline' && !v.paused")
            // The tray follows the window used last (WIN-7), which a run that never activates Airc doesn't change.
            expect("\(name): the system window is closed\(tray ? " and the tray leaves the tab out" : "")", {
                page(tab()).map(systemPictureInPictureOpen) == false && (!tray || media?.players.contains { $0.tabID == tab() } == false)
            })
        }

        if returns {
            // a. The tab isn't the selected one.
            endCase()
            beginCase("hidden tab")
            openPictureInPicture("hidden tab", { video }) { [self] in c.show(other, focus: false) }
            pressReturn("hidden tab", { video })
            returned("hidden tab", { video }, window: { [self] in c }, space: { firstSpace })
            run { [self] in page(video)?.evaluate("v.pause(); true", completion: nil) }

            // b. The tab is in another Space.
            endCase()
            beginCase("other Space")
            run { [self] in
                do {
                    secondSpace = try c.store.createSpace(name: "PiP Return", after: firstSpace).id
                    spaced = try c.store.openTab(url: "http://localhost:\(port)/video", inSpace: secondSpace).id
                    c.switchToSpace(secondSpace, animated: false)
                    c.reloadAll(animated: false); c.show(spaced, focus: false)
                } catch { check(false, "pipreturn: Space setup \(error)") }
            }
            expect("another Space's video page loads", timeout: 15, { page(spaced)?.isLoading == false && page(spaced)?.title == "Video" })
            expectPage("another Space's video can play", { spaced }, "v.readyState > 2", timeout: 10)
            openPictureInPicture("other Space", { spaced }) { [self] in c.switchToSpace(firstSpace, animated: false); c.show(other, focus: false) }
            pressReturn("other Space", { spaced })
            returned("other Space", { spaced }, window: { [self] in c }, space: { secondSpace })
            run { [self] in if let p = page(spaced) { p.evaluate("v.pause(); true", completion: nil) } }

            // c. Its window is behind another Airc window (on the same frame, so it's covered).
            endCase()
            beginCase("window behind")
            run { [self] in c.switchToSpace(firstSpace, animated: false); c.show(video, focus: false) }
            openPictureInPicture("window behind", { video }) { [self] in
                c.show(other, focus: false)
                frontSpace = (try? c.store.createSpace(name: "Front Window", after: firstSpace).id) ?? ""
                second = app?.openNewWindow(from: c, spaceID: frontSpace, commandBar: false, frame: c.window.frame)
            }
            func order() -> String {
                let o = NSApp.orderedWindows
                return [("tab's", c.window), ("other", second?.window)].map { n, w in
                    "\(n) #\(w.flatMap { o.firstIndex(of: $0) }.map(String.init) ?? "-") \(w?.isOnActiveSpace == true ? "on" : "off") the active Space"
                }.joined(separator: ", ")
            }
            run { [self] in
                second?.window.orderFront(nil)
                let o = NSApp.orderedWindows
                verdict(second.map { w in (o.firstIndex(of: w.window) ?? .max) < (o.firstIndex(of: c.window) ?? .max) } == true,
                      "pipreturn: window behind: another window is in front of the tab's (\(order()))")
            }
            pressReturn("window behind", { video })
            returned("window behind", { video }, window: { [self] in c }, space: { firstSpace }, tray: false)
            run { [self] in
                let o = NSApp.orderedWindows
                verdict(second.map { w in (o.firstIndex(of: c.window) ?? .max) < (o.firstIndex(of: w.window) ?? .max) } == true,
                      "pipreturn: window behind: the tab's window comes to the front (without activating Airc: \(!NSApp.isActive); \(order()))")
                second?.window.performClose(nil); second = nil
            }
            wait(0.5)

            endCase()
            beginCase("close")
            // d. ✕ pauses through WebKit's stop action, then dismisses the native window.
            // PIP delivers its own animation-completed callback; the tab stays where it is.
            var asked = 0
            openPictureInPicture("close", { video }) { [self] in c.show(other, focus: false) }
            run {
                asked = page(video).map(returnRequestCount) ?? 0
                verdict(PiPAgentProbe.current.map { PiPAgentProbe.stop($0) } == true,
                        "pipreturn: close: the native dismiss action is dispatched")
            }
            expectPage("close: ✕ pauses the video", { video }, "v.paused")
            run { [self] in
                verdict(c.shownTabID == other && page(video).map(returnRequestCount) == asked, "pipreturn: close: ✕ doesn't bring the tab back")
            }
            step { done in page(video)?.closeSystemPictureInPicture(pause: true) { done() } ?? done() }
            expectPage("close: the picture in picture is closed", { video }, "!document.pictureInPictureElement && v.webkitPresentationMode === 'inline'")

            endCase()
            beginCase("hide")
            // e. The tray's Hide (Arc's –): the window goes, playback goes on, Picture in Picture brings it back.
            openPictureInPicture("hide", { video }) { [self] in c.show(other, focus: false) }
            expect("hide: the tray knows the system window is open", { media?.players.first { $0.tabID == video }?.inSystemPictureInPicture == true })
            step { done in
                guard let p = media?.players.first(where: { $0.tabID == video }) else { return done() }
                media?.systemMiniPlayer("hide", p, completion: done)
            }
            expectPage("hide: the window goes and the video plays on", { video },
                       "!document.pictureInPictureElement && v.webkitPresentationMode === 'inline' && !v.paused")
            expect("hide: the player stays in the tray", {
                media?.players.first { $0.tabID == video }.map { !$0.inSystemPictureInPicture && $0.session.playback == .playing } == true
            })
            step { done in
                guard let p = media?.players.first(where: { $0.tabID == video }) else { return done() }
                media?.systemMiniPlayer("pip", p)
                done()
            }
            expectPage("hide: Picture in Picture brings it back", { video },
                       "document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture'")
            step { done in
                guard let p = media?.players.first(where: { $0.tabID == video }) else { return done() }
                media?.systemMiniPlayer("close", p, completion: done)
            }
            expectPage("hide: Close pauses", { video }, "!document.pictureInPictureElement && v.paused")
            endCase()

        }

        if tray {
            // f. Two players stack, the latest first (as Arc's tray); Close Player (Arc's Close Mini Player) pauses and hides
            // one until its tab plays again or you go back to it.
            beginCase("close players")
            // The video tab hidden and paused: a second, paused player.
            value({ video }, "v.play(); true") { _ in }
            expectPage("f: the video plays", { video }, "!v.paused && v.currentTime > 0")
            run { [self] in c.show(other, focus: false) }
            value({ video }, "v.pause(); true") { _ in }
            func rows() -> [String] { media?.players.map(\.tabID) ?? [] }
            run { if let p = media?.sessions[player] { media?.perform("play", p) } }
            expect("two players stack, the playing one first, the paused one under it", { rows() == [player, video] },
                   { "\(media?.players.map { "\($0.title) \($0.session.playback)" } ?? [])" })
            run { if let p = media?.players.first(where: { $0.tabID == video }) { media?.closePlayer(p) } }
            expect("Close Player hides the paused row and keeps the other", { rows() == [player] && media?.sessions[video] != nil })
            run { if let p = media?.players.first(where: { $0.tabID == player }) { media?.closePlayer(p) } }
            expectPage("Close Player pauses the song", { player }, "audio.paused")
            expect("and its row goes", { rows().isEmpty && media?.sessions[player]?.session.playback == .paused })
            value({ player }, "audio.play(); true") { _ in }
            expect("playing again brings its row back", { rows() == [player] })
            run { [self] in c.show(video, focus: false) }
            wait(0.3)
            run { [self] in c.show(other, focus: false) }
            expect("going back to a closed player's tab and leaving it brings it back", { rows().contains(video) })
            run { if let p = media?.sessions[player] { media?.perform("pause", p) } }
            endCase()

        }

        if returns {
            // MARK: 3. Arc's corner

            run { [self] in
                let v = PiPControlsView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
                v.layout()
                check(v.close.superview === v.content && v.hide.superview === v.content && v.minimize.superview == nil && v.minimize.isHidden,
                      "pipreturn: the Mini Player's corner has ✕ and – only, as Arc's")
                check(v.hide.frame.minY == v.close.frame.minY && v.hide.frame.minX > v.close.frame.maxX && v.hide.label == "Hide Mini Player",
                      "pipreturn: – sits beside ✕ and hides the window")
            }

        }

        if aspect { pipAspectCase(port: { port }, firstSpace: { firstSpace }, verdict: verdict, beginCase: beginCase, endCase: endCase) }

        run { [self] in
            second?.window.performClose(nil)
            for id in [player, video, other, spaced] where !id.isEmpty { c.closeTab(id) }
            for s in [secondSpace, frontSpace] where !s.isEmpty { try? c.store.deleteSpace(s) }
            c.switchToSpace(firstSpace, animated: false)
            server?.stop(); ProtectedMedia.shared.testHosts = []
        }
        wait(0.3)
    }


    // MARK: 4. Each video keeps its own shape

    /// A 16:9 video in picture in picture, collapsed to the pill and back, closed; then a 9:16 video in the same tab, and
    /// in another tab; each switched to 16:9 while it floats (an ad, then the content). Chromium's window (Airc's
    /// controls) must take each video's aspect ratio within 1%, keep the first window's width or area (roughly its
    /// size), inside the visible frame. The system window (WebKit) is macOS's: what it does is recorded, not asserted.
    private func pipAspectCase(port: @escaping () -> UInt16, firstSpace: @escaping () -> String,
                               verdict: @escaping (Bool, String) -> Void, beginCase: (String) -> Void, endCase: () -> Void) {
        var tab = "", other = "", first = NSRect.zero
        let main = c
        func page() -> EngineTab? { main?.engineTab(for: tab) }
        beginCase("aspect")
        run { [self] in
            do {
                tab = try main!.store.openTab(url: "http://127.0.0.1:\(port())/aspect", inSpace: firstSpace()).id
                main!.reloadAll(animated: false); main!.show(tab, focus: false)
            } catch { check(false, "pipreturn: aspect setup \(error)") }
        }
        step { [self] done in waitUntil({ page()?.isLoading == false && page()?.title == "Aspect" }, timeout: 15) { done() } }
        #if canImport(AircCore)
        if let chromium = app?.engine as? ChromiumEngine {
            var current = { tab }
            func page() -> EngineTab? { main?.engineTab(for: current()) }
            func window() -> NSWindow? { page().flatMap { PiPEngineOverlay.state($0, in: chromium)?["window"] as? NSWindow } }
            func shape(_ w: NSWindow) -> Double { w.frame.width / max(1, w.frame.height) }
            func load(_ src: String) {
                step { done in
                    guard let p = page() else { return done() }
                    chromium.devToolsCall("Runtime.evaluate", params: ["expression": "load('\(src)').then(function(){ return v.videoWidth / v.videoHeight; })",
                                          "userGesture": true, "awaitPromise": true, "returnByValue": true], in: p) { _, _ in done() }
                }
            }
            func open(_ what: String) {
                step { [self] done in
                    guard let p = page() else { return done() }
                    chromium.devToolsCall("Runtime.evaluate", params: ["expression": "v.requestPictureInPicture().then(function(){ return 'in'; })",
                                          "userGesture": true, "awaitPromise": true, "returnByValue": true], in: p) { _, error in
                        self.note("pipreturn: aspect: \(what): requestPictureInPicture \(error.map { "\($0)" } ?? "ok")")
                        self.waitUntil({ window()?.isVisible == true }, timeout: 6) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done) }
                    }
                }
            }
            func expectShape(_ what: String, _ ratio: Double, sizeLike: Bool = false) {
                step { [self] done in
                    waitUntil({ window().map { abs(shape($0) / ratio - 1) <= 0.01 } == true }, timeout: 3) {
                        guard let w = window() else { verdict(false, "pipreturn: aspect: \(what): no picture in picture window"); return done() }
                        let f = w.frame, inside = (w.screen?.visibleFrame).map { $0.contains(f) } ?? false
                        let area = f.width * f.height, firstArea = first.width * first.height
                        // Roughly the size: its width or its area (the lead's spec).
                        let width = f.width / max(1, first.width), size = area / max(1, firstArea)
                        verdict(abs(shape(w) / ratio - 1) <= 0.01 && inside && (!sizeLike || abs(width - 1) < 0.1 || abs(size - 1) < 0.2),
                                String(format: "pipreturn: aspect: %@: %.0f×%.0f, %.4f for %.4f (within 1%%), inside the visible frame: %@%@",
                                       what, f.width, f.height, shape(w), ratio, inside ? "yes" : "no",
                                       sizeLike ? String(format: ", width %.0f%% and area %.0f%% of the first", 100 * width, 100 * size) : ""))
                        if first == .zero { first = f }
                        done()
                    }
                }
            }
            load("/movie.mp4")
            open("16:9")
            expectShape("a 16:9 video", 16.0 / 9)
            run { if let p = page() { PiPOverlays.shared.controls(for: p)?.minimize.action?() } }
            wait(0.8)
            run { if let p = page() { PiPOverlays.shared.controls(for: p)?.miniPlayer.setMinimized(false, animated: false) } }
            wait(0.6)
            expectShape("16:9 after the pill and back", 16.0 / 9)
            run { if let p = page() { chromium.closePictureInPicture(p) } }
            wait(0.8)
            // The same page's next video (the owner's: a song, then its Canvas): Chromium's window learns its size late.
            load("/tall.mp4")
            open("9:16")
            expectShape("then a 9:16 video in the same tab", 9.0 / 16, sizeLike: true)
            load("/movie.mp4")
            expectShape("its source switched to 16:9 while it floats", 16.0 / 9)
            run { if let p = page() { chromium.closePictureInPicture(p) } }
            wait(0.8)
            // Another tab's 9:16 video: its size is known when its window opens.
            run { [self] in
                other = (try? main!.store.openTab(url: "http://127.0.0.1:\(port())/aspect", inSpace: firstSpace()).id) ?? ""
                current = { other }
                main!.reloadAll(animated: false); main!.show(other, focus: false)
            }
            step { [self] done in waitUntil({ page()?.isLoading == false && page()?.title == "Aspect" }, timeout: 15) { done() } }
            load("/tall.mp4")
            open("9:16")
            expectShape("then a 9:16 video in another tab", 9.0 / 16, sizeLike: true)
            load("/movie.mp4")
            expectShape("that one switched to 16:9 while it floats", 16.0 / 9)
            run { if let p = page() { chromium.closePictureInPicture(p) } }
            wait(0.5)
        }
        #endif
        if let p = page() as? WebKitTab {
            // macOS's own window: WebKit gives its controller the video's shape; the agent draws the window.
            func observe(_ what: String) {
                wait(0.8)
                run { [self] in
                    let ratio = (PiPAgentProbe.current?.value(forKey: "aspectRatio") as? NSValue)?.sizeValue
                    let agent = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                        .filter { ($0[kCGWindowOwnerName as String] as? String)?.contains("PIP") == true }
                        .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
                    note("pipreturn: aspect (system window, observed): \(what): controller \(ratio.map { "\($0.width)×\($0.height)" } ?? "?"), " +
                         "PIPAgent windows \(agent.map { String(format: "%.0f×%.0f (%.3f)", $0.width, $0.height, $0.width / max(1, $0.height)) })")
                }
            }
            func play(_ src: String) { step { done in p.evaluate("load('\(src)'); true") { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done) } } }
            play("/movie.mp4")
            step { done in p.requestSystemPictureInPicture { _ in done() } }
            observe("a 16:9 video")
            step { done in p.closeSystemPictureInPicture(pause: false) { done() } }
            play("/tall.mp4")
            step { done in p.requestSystemPictureInPicture { _ in done() } }
            observe("then a 9:16 video")
            play("/movie.mp4")
            observe("its source switched to 16:9 while it floats")
            step { done in p.closeSystemPictureInPicture(pause: true) { done() } }
        }
        run { [self] in for id in [tab, other] where !id.isEmpty { main?.closeTab(id) } }
        endCase()
    }
}

// The fix under test is reached only through these (and the tray's Hide below), so the check also runs on a tree
// without it.
private func returnRequestCount(_ page: WebKitTab) -> Int { SystemPictureInPicture.returnRequests.filter { $0 == ObjectIdentifier(page) }.count }
private func systemPictureInPictureOpen(_ page: WebKitTab) -> Bool { SystemPictureInPicture.isOpen(page) }
private func automaticPictureInPicture(_ page: WebKitTab, _ done: @escaping (String) -> Void) {
    page.requestSystemPictureInPicture(automatic: true, completion: done)
}

/// The system picture in picture window is PIPAgent's; this process has WebKit's PIPViewController, which gets the
/// window's button presses from the agent and hands them to its delegate (WebKit's VideoPresentationInterfaceMac):
/// pipShouldClose: for the return button, pipActionStop: for ✕. The check records each controller WebKit sets up and
/// calls the delegate the same way.
enum PiPAgentProbe {
    private final class Weak { weak var pip: NSObject?; init(_ p: NSObject) { pip = p } }
    private static var made: [Weak] = []
    private static let presented = NSMapTable<NSObject, NSObject>.weakToWeakObjects()
    private static var installed = false

    static func install() -> Bool {
        if installed { return true }
        _ = dlopen("/System/Library/PrivateFrameworks/PIP.framework/PIP", RTLD_NOW)
        let sel = NSSelectorFromString("setDelegate:")
        let presentSelector = NSSelectorFromString("presentViewControllerAsPictureInPicture:")
        guard let cls = NSClassFromString("PIPViewController"), let m = class_getInstanceMethod(cls, sel),
              let presentation = class_getInstanceMethod(cls, presentSelector) else { return false }
        typealias Setter = @convention(c) (NSObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(m), to: Setter.self)
        let block: @convention(block) (NSObject, AnyObject?) -> Void = { pip, delegate in
            made = made.filter { $0.pip != nil && $0.pip !== pip } + [Weak(pip)]
            original(pip, sel, delegate)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
        typealias Present = @convention(c) (NSObject, Selector, NSObject) -> Void
        let originalPresent = unsafeBitCast(method_getImplementation(presentation), to: Present.self)
        let presentationBlock: @convention(block) (NSObject, NSObject) -> Void = { pip, content in
            presented.setObject(content, forKey: pip)
            originalPresent(pip, presentSelector, content)
        }
        method_setImplementation(presentation, imp_implementationWithBlock(presentationBlock))
        installed = true
        return true
    }

    /// The newest controller that WebKit still drives.
    static var current: NSObject? { made.reversed().compactMap(\.pip).first { delegate(of: $0) != nil } }

    private static func delegate(of pip: NSObject) -> NSObject? { pip.value(forKey: "delegate") as? NSObject }

    /// The return button. nil: no delegate answers it.
    static func shouldClose(_ pip: NSObject) -> Bool? {
        let s = NSSelectorFromString("pipShouldClose:")
        guard let d = delegate(of: pip), d.responds(to: s) else { return nil }
        typealias F = @convention(c) (NSObject, Selector, NSObject) -> ObjCBool
        return unsafeBitCast(d.method(for: s), to: F.self)(d, s, pip).boolValue
    }

    /// ✕: send the stop action and dismiss the native controller. PIP owns the
    /// animation-completed callback; sending pipDidClose: ourselves races its real close.
    @discardableResult static func stop(_ pip: NSObject) -> Bool {
        let action = NSSelectorFromString("pipActionStop:")
        let dismiss = NSSelectorFromString("dismissViewController:")
        guard let d = delegate(of: pip), d.responds(to: action), pip.responds(to: dismiss),
              let content = presented.object(forKey: pip) else { return false }
        typealias F = @convention(c) (NSObject, Selector, NSObject) -> Void
        unsafeBitCast(d.method(for: action), to: F.self)(d, action, pip)
        unsafeBitCast(pip.method(for: dismiss), to: F.self)(pip, dismiss, content)
        return true
    }
}

/// Loopback pages and generated silent media for `--script pipreturn`.
final class PiPReturnServer {
    static let trackSeconds = 90
    /// What the pages report next to a failed expectation.
    static let state = "(window.info || window.v) ? {info: window.info, ready: window.fixtureReady, play: window.playResult, " +
        "audio: window.audio && {paused: audio.paused, t: audio.currentTime, rs: audio.readyState}, " +
        "video: window.v && {paused: v.paused, t: v.currentTime, mode: v.webkitPresentationMode, rs: v.readyState}, " +
        "pip: !!document.pictureInPictureElement, visibility: document.visibilityState} : null"
    private let listener: NWListener?
    private let queue = DispatchQueue(label: "airc.test.pipreturn-server")
    private var track = Data(), movie = Data(), clip = Data(), tall = Data()
    static let clipSeconds = 8
    private(set) var problem = ""

    init() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        listener = try? NWListener(using: params)
    }

    func start(_ ready: @escaping (UInt16?) -> Void) {
        guard let listener else { problem = "no listener"; return ready(nil) }
        PiPReturnMedia.make(seconds: Self.trackSeconds, video: false, file: nil) { [self] track in
            let file = AppPaths.dataDirectory.appendingPathComponent("pipreturn-video.mp4")
            PiPReturnMedia.make(seconds: 20, video: true, file: file) { [self] movie in
              PiPReturnMedia.make(seconds: Self.clipSeconds, video: true, file: file) { [self] clip in
               PiPReturnMedia.make(seconds: 20, video: true, size: CGSize(width: 180, height: 320), file: file) { [self] tall in
                try? FileManager.default.removeItem(at: file)
                guard let track, let movie, let clip, let tall else {
                    problem = "media: track \(track?.count ?? -1) B, video \(movie?.count ?? -1) B, clip \(clip?.count ?? -1) B, " +
                        "tall \(tall?.count ?? -1) B"
                    return ready(nil)
                }
                queue.sync { self.track = track; self.movie = movie; self.clip = clip; self.tall = tall }
                var answered = false
                listener.stateUpdateHandler = { [listener] state in
                    let port: UInt16?
                    switch state {
                    case .ready: port = listener.port?.rawValue
                    case .failed, .cancelled: port = nil
                    default: return
                    }
                    DispatchQueue.main.async {
                        guard !answered else { return }
                        answered = true
                        if port == nil { self.problem = "listener \(state)" }
                        ready(port)
                    }
                }
                listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
                listener.start(queue: queue)
               }
              }
            }
        }
    }

    func stop() { listener?.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return c.cancel() }
            let buffer = buffer + (data ?? Data())
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return complete || error != nil || buffer.count > 65536 ? c.cancel() : self.receive(c, buffer)
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let path = String(lines.first?.split(separator: " ").dropFirst().first?.split(separator: "?").first ?? "/")
            let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            switch path {
            case "/player": self.send(c, "200 OK", "text/html; charset=utf-8", Data(Self.playerPage.utf8))
            case "/video": self.send(c, "200 OK", "text/html; charset=utf-8", Data(Self.videoPage.utf8))
            case "/aspect": self.send(c, "200 OK", "text/html; charset=utf-8", Data(Self.aspectPage.utf8))
            case "/track.mp4": self.send(c, "200 OK", "audio/mp4", self.track)
            case "/movie.mp4": self.sendRange(c, self.movie, type: "video/mp4", range: range)
            case "/clip.mp4": self.sendRange(c, self.clip, type: "video/mp4", range: range)
            case "/tall.mp4": self.sendRange(c, self.tall, type: "video/mp4", range: range)
            case "/art.png": self.send(c, "200 OK", "image/png", Self.artwork)
            default: self.send(c, "404 Not Found", "text/plain", Data("not found".utf8))
            }
        }
    }

    private func send(_ c: NWConnection, _ status: String, _ type: String, _ body: Data, _ extra: String = "") {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    /// WebKit's media loading asks for byte ranges.
    private func sendRange(_ c: NWConnection, _ data: Data, type: String, range: String?) {
        guard let r = range, r.hasPrefix("bytes="), !data.isEmpty else { return send(c, "200 OK", type, data, "Accept-Ranges: bytes\r\n") }
        let bounds = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        let from = min(bounds.first.flatMap { $0 } ?? 0, data.count - 1)
        let to = min(bounds.count > 1 ? (bounds[1] ?? data.count - 1) : data.count - 1, data.count - 1)
        guard from <= to else { return send(c, "416 Range Not Satisfiable", type, Data(), "Content-Range: bytes */\(data.count)\r\n") }
        send(c, "206 Partial Content", type, data.subdata(in: from..<(to + 1)),
             "Accept-Ranges: bytes\r\nContent-Range: bytes \(from)-\(to)/\(data.count)\r\n")
    }

    private static let artwork: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [NSColor(red: 0.12, green: 0.73, blue: 0.33, alpha: 1), NSColor(red: 0.07, green: 0.25, blue: 0.2, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: 96, height: 96), angle: -45)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }()

    static let playerPage = """
    <!doctype html><meta charset="utf-8"><title>Player</title>
    <style>body{margin:0;background:#121212;color:#fff;font:15px system-ui;padding:24px}
    .VideoPlayer__container video{width:240px;height:240px;object-fit:cover;border-radius:8px;display:block}</style>
    <div class="VideoPlayer__container"></div><button id="play">Play</button><p id="t">Ready</p>
    <script>
    // Spotify's player: createPlayer(type) is document.createElement(type), and its container manager only puts video
    // into the document. MediaSource buffers; protected audio through Web Audio (an AudioContext made up front, resumed
    // after play); metadata and handlers after play, and no setPositionState (Spotify's web player never calls it).
    // Its Canvas: a short muted looping clip in the page, playing while the music plays.
    var ms = navigator.mediaSession, track = 1, info = {eme: 'none', mse: 'pending', webaudio: 'none'};
    var audio = document.createElement('audio'), ctx = null;
    audio.autoplay = false; audio.loop = false; audio.volume = 0.6;
    function meta() {
      ms.metadata = new MediaMetadata({title: 'Loopback Track ' + track, artist: 'Fixture Artist', album: 'Loopback',
        artwork: [{src: '/art.png', sizes: '96x96'}]});
      document.getElementById('t').textContent = ms.metadata.title;
    }
    function sync() {
      ms.playbackState = audio.paused ? 'paused' : 'playing';
      // The Canvas loops while the music plays (Spotify's LoopOnPlayback).
      if (audio.paused) canvas.pause(); else canvas.play().catch(function(){});
    }
    var canvas = document.createElement('video'); canvas.muted = true; canvas.loop = true; canvas.playsInline = true;
    canvas.preload = 'auto'; canvas.src = '/clip.mp4'; canvas.addEventListener('leavepictureinpicture', sync);
    document.querySelector('.VideoPlayer__container').appendChild(canvas); window.canvasVideo = canvas;
    (async function() {
      try {
        var access = await navigator.requestMediaKeySystemAccess('org.w3.clearkey', [{initDataTypes: ['keyids', 'cenc'],
          audioCapabilities: [{contentType: 'audio/mp4; codecs="mp4a.40.2"'}]}]);
        await audio.setMediaKeys(await access.createMediaKeys()); info.eme = 'clearkey';
      } catch (e) { info.eme = 'none (' + e.name + ')'; }
      try {
        ctx = new AudioContext(); var gain = ctx.createGain(); gain.gain.value = 0;
        ctx.createMediaElementSource(audio).connect(gain); gain.connect(ctx.destination); info.webaudio = ctx.state;
      } catch (e) { info.webaudio = 'failed ' + e.name; }
      var source = new MediaSource();
      audio.src = URL.createObjectURL(source);
      await new Promise(function(r){ source.addEventListener('sourceopen', r, {once: true}); });
      var buffer = source.addSourceBuffer('audio/mp4; codecs="mp4a.40.2"');
      buffer.appendBuffer(await (await fetch('/track.mp4')).arrayBuffer());
      await new Promise(function(r, j){ buffer.addEventListener('updateend', r, {once: true}); buffer.addEventListener('error', j, {once: true}); });
      source.endOfStream();
      info.mse = source.readyState + ' ' + audio.duration.toFixed(1) + ' s';
      if (canvas.readyState < 1) await new Promise(function(r){ canvas.addEventListener('loadedmetadata', r, {once: true}); });
      window.fixtureReady = 'ready';
    })().catch(function(e){ info.mse = 'failed ' + e; window.fixtureReady = 'failed'; });
    document.getElementById('play').addEventListener('click', function() {
      new Promise(function(r){ r(audio.play()); }).then(function(){ return ctx && ctx.resume(); }).then(function(){
        if (ctx) info.webaudio = ctx.state;
        meta(); sync();
        ms.setActionHandler('play', function(){ audio.play().then(sync); });
        ms.setActionHandler('pause', function(){ audio.pause(); sync(); });
        ms.setActionHandler('nexttrack', function(){ track++; meta(); sync(); });
        ms.setActionHandler('previoustrack', function(){ if (track > 1) track--; meta(); sync(); });
        ms.setActionHandler('seekto', function(e){ audio.currentTime = e.seekTime; sync(); });
        window.playResult = 'playing';
      }, function(e){ window.playResult = 'error ' + e.name; });
    });
    </script>
    """

    static let aspectPage = """
    <!doctype html><meta charset="utf-8"><title>Aspect</title>
    <body style="margin:0;background:#000"><video id="v" loop playsinline style="width:100%;display:block"></video>
    <script>var v = document.getElementById('v'); function load(src){ v.src = src; return v.play(); }</script>
    """

    static let videoPage = """
    <!doctype html><meta charset="utf-8"><title>Video</title>
    <body style="margin:0;background:#0d1b2a"><video id="v" src="/movie.mp4" loop playsinline style="width:100%;display:block"></video>
    <script>
    var v = document.getElementById('v');
    navigator.mediaSession.metadata = new MediaMetadata({title: 'Fixture Video', artist: 'Loopback'});
    </script>
    """
}

/// Silent AAC (fragmented, as MediaSource takes it, or in a plain MP4 with a moving H.264 picture), made with
/// AVAssetWriter in the run, so the repo carries no media files.
final class PiPReturnMedia: NSObject, AVAssetWriterDelegate {
    private var segments = Data()
    private var keep: PiPReturnMedia?
    private let queue = DispatchQueue(label: "airc.test.pipreturn-media")
    private var pending = 0
    private var writer: AVAssetWriter?

    static func make(seconds: Int, video: Bool, size: CGSize = CGSize(width: 320, height: 180), file: URL?,
                     _ done: @escaping (Data?) -> Void) {
        let m = PiPReturnMedia()
        m.keep = m
        m.write(seconds: seconds, video: video, size: size, file: file) { data in
            m.keep = nil
            DispatchQueue.main.async { done(data) }
        }
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        segments.append(segmentData)
    }

    private func write(seconds: Int, video: Bool, size: CGSize, file: URL?, _ done: @escaping (Data?) -> Void) {
        let width = Int(size.width), height = Int(size.height)
        let w: AVAssetWriter
        if let file {
            try? FileManager.default.removeItem(at: file)
            guard let made = try? AVAssetWriter(outputURL: file, fileType: .mp4) else { return done(nil) }
            w = made
        } else {
            w = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
            w.outputFileTypeProfile = .mpeg4AppleHLS
            w.preferredOutputSegmentInterval = CMTime(seconds: 6, preferredTimescale: 1)
            w.initialSegmentStartTime = .zero
            w.delegate = self
        }
        writer = w
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        audio.expectsMediaDataInRealTime = false
        guard w.canAdd(audio) else { return done(nil) }
        w.add(audio)
        var picture: AVAssetWriterInputPixelBufferAdaptor?
        if video {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height])
            input.expectsMediaDataInRealTime = false
            guard w.canAdd(input) else { return done(nil) }
            w.add(input)
            picture = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        }
        guard w.startWriting() else { return done(nil) }
        w.startSession(atSourceTime: .zero)
        let finish = { [self] in
            pending -= 1
            guard pending == 0 else { return }
            w.finishWriting { [self] in
                guard w.status == .completed else { return done(nil) }
                done(file.flatMap { try? Data(contentsOf: $0) } ?? segments)
            }
        }
        pending = picture == nil ? 1 : 2
        // A second of 16-bit mono zeros per buffer.
        var asbd = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var second = 0, audioDone = false
        audio.requestMediaDataWhenReady(on: queue) {
            while audio.isReadyForMoreMediaData, second < seconds, let format {
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 88_200, blockAllocator: nil,
                    customBlockSource: nil, offsetToData: 0, dataLength: 88_200, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                var sample: CMSampleBuffer?
                if let block {
                    CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: 88_200)
                    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                        sampleCount: 44_100, presentationTimeStamp: CMTime(value: CMTimeValue(second * 44_100), timescale: 44_100),
                        packetDescriptions: nil, sampleBufferOut: &sample)
                }
                guard let sample, audio.append(sample) else { second = seconds; break }
                second += 1
            }
            if second >= seconds || format == nil, !audioDone { audioDone = true; audio.markAsFinished(); finish() }
        }
        guard let picture else { return }
        var frame = 0, videoDone = false
        let frames = seconds * 10
        picture.assetWriterInput.requestMediaDataWhenReady(on: queue) {
            while picture.assetWriterInput.isReadyForMoreMediaData, frame < frames {
                var buffer: CVPixelBuffer?
                guard let pool = picture.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                      let buffer else { frame = frames; break }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    // A slow hue walk: BGRA rows of one colour.
                    let hue = Double(frame % 120) / 120
                    let rgb = NSColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1).usingColorSpace(.deviceRGB) ?? .gray
                    let px: UInt32 = UInt32(rgb.blueComponent * 255) | UInt32(rgb.greenComponent * 255) << 8
                        | UInt32(rgb.redComponent * 255) << 16 | 0xFF00_0000
                    let rowWords = CVPixelBufferGetBytesPerRow(buffer) / 4
                    let words = base.bindMemory(to: UInt32.self, capacity: rowWords * height)
                    for i in 0..<(rowWords * height) { words[i] = px }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard picture.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)) else { frame = frames; break }
                frame += 1
            }
            if frame >= frames, !videoDone { videoDone = true; picture.assetWriterInput.markAsFinished(); finish() }
        }
    }
}
#endif
