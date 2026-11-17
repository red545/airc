// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import Combine
#if canImport(AircCore)
import AircCore
#endif

/// `--script medialib-noise`: one-shot sounds aren't players. A background tab plays a 0.5 s ping through an Audio
/// element, a Web Audio beep and a 2 s sound (each three times, as a chat's pings come): no tray row and no session in
/// the app at any moment (sampled every frame, so no flash). Then a 30 s track without metadata and a Media Session
/// page still get their player. Loopback pages; the files are silent and the beep is at -80 dB.
extension SnapshotRunner {
    func mediaNoise(_ x: MediaLibContext) {
        var home = "", noise = "", other = "", track = "", music = ""
        var seen: [String] = []
        var engineSaw: Set<String> = []
        var label = ""
        var sampler: Timer?
        var sink: AnyCancellable?
        let media = { MediaLibrary.shared.media }
        run { [self] in
            do {
                home = c.currentSpaceID
                noise = try c.store.openTab(url: x.base + "/noise", inSpace: home).id
                other = try c.store.openTab(url: "data:text/html,<title>Reading</title>", inSpace: home).id
                c.reloadAll(animated: false)
                c.show(noise, focus: false)
            } catch { check(false, "noise: setup (\(error))") }
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: noise)?.title == "Noise" }, timeout: 10) { done() } }
        // Off screen, as the tray shows only tabs you aren't looking at.
        run { [self] in c.show(other, focus: false) }
        wait(0.5)
        run { [self] in
            sink = media()?.$players.sink { players in
                if seen.count < 40, players.contains(where: { $0.tabID == noise }) { seen.append("\(label): tray row") }
            }
            sampler = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                if seen.count < 40, let p = media()?.sessions[noise] { seen.append("\(label): session \(p.session.playback.rawValue)") }
                // What the engine itself reports: proves the sound reached it (a session the app then leaves out).
                #if canImport(AircCore)
                if let chromium = self.app?.engine as? ChromiumEngine, let page = self.c.engineTab(for: noise),
                   let core = chromium.core(of: page), let d = Pass13.value(core, "mediaSession") as? [String: Any],
                   (d["active"] as? NSNumber)?.boolValue == true {
                    engineSaw.insert(label)
                }
                #endif
            }
        }
        // Each sound starts with its tab on screen (WebKit doesn't start Web Audio in a hidden page), which then goes
        // off screen at once, where a player would get a tray row; the sampler watches both throughout.
        for (name, js) in [("0.5 s Audio ping", "ping('/ping.wav')"), ("Web Audio beep", "beep()"), ("2 s sound", "ping('/short.wav')")] {
            run { [self] in label = name; c.show(noise, focus: false) }
            for _ in 0..<3 {
                gestureEvaluate({ noise }, js)
                wait(0.1)
            }
            run { [self] in c.show(other, focus: false) }
            step { [self] done in waitForLog(noise, ended: 3, timeout: 10) { _ in done() } }
            wait(0.5)
            step { [self] done in
                waitForLog(noise, ended: 3, timeout: 0) { log in
                    self.check(log.components(separatedBy: "ended").count - 1 >= 3, "noise: the \(name) played, three times (page log \(log))")
                    if self.isChromiumEngine {
                        self.check(engineSaw.contains(name), "noise: Chromium had a media session for the \(name) (engine saw: \(engineSaw.sorted()))")
                    }
                    self.check(!seen.contains { $0.hasPrefix(name) }, "noise: the \(name) shows no mini player, not even briefly (\(seen))")
                    self.check(media()?.players.isEmpty == true, "noise: the tray is empty after the \(name) (\(media()?.players.map(\.title) ?? []))")
                    self.noiseEval(noise, "log = []")
                    done()
                }
            }
        }
        run {
            sampler?.invalidate()
            sink = nil
            _ = sink
        }
        capture("medialib-noise-none")
        // Real media keeps its player: a 30 s track with no metadata, and a Media Session page.
        run { [self] in
            do {
                track = try c.store.openTab(url: x.base + "/track", inSpace: home).id
                c.reloadAll(animated: false)
                c.show(track, focus: false)
            } catch { check(false, "noise: track setup (\(error))") }
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: track)?.title == "Track" }, timeout: 10) { done() } }
        gestureEvaluate({ track }, "play()")
        // Playing before it leaves the screen: WebKit doesn't start audio in a hidden page (with or without this change).
        step { [self] done in waitUntil({ media()?.sessions[track]?.session.playback == .playing }, timeout: 8) { done() } }
        run { [self] in c.show(other, focus: false) }
        step { [self] done in waitUntil({ media()?.players.first { $0.tabID == track }?.session.playback == .playing }, timeout: 8) { done() } }
        run { [self] in
            let p = media()?.players.first { $0.tabID == track }
            check(p?.session.playback == .playing && p?.title == "Track",
                  "noise: a 30 s track (no metadata) still gets its mini player (\(p.map { "\($0.title) \($0.session.playback) \($0.session.duration ?? -1)" } ?? "none"))")
        }
        capture("medialib-noise-track")
        gestureEvaluate({ track }, "pause()")
        run { [self] in
            do {
                music = try c.store.openTab(url: x.base + "/music", inSpace: home).id
                c.reloadAll(animated: false)
                c.show(music, focus: false)
            } catch { check(false, "noise: music setup (\(error))") }
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: music)?.title.contains("Music") == true }, timeout: 10) { done() } }
        gestureEvaluate({ music }, "a.play().then(function(){ ms.playbackState = 'playing'; return true; })")
        // Playing before it leaves the screen: WebKit doesn't start audio in a hidden page (with or without this change).
        step { [self] done in waitUntil({ media()?.sessions[music]?.session.playback == .playing }, timeout: 8) { done() } }
        run { [self] in c.show(other, focus: false) }
        step { [self] done in waitUntil({ media()?.players.first { $0.tabID == music }?.session.playback == .playing }, timeout: 8) { done() } }
        run { [self] in
            let p = media()?.players.first { $0.tabID == music }
            check(p?.title == "Fixture Song" && p?.session.playback == .playing,
                  "noise: a Media Session page still gets its mini player (\(p.map { "\($0.title) \($0.session.playback)" } ?? "none"))")
        }
        gestureEvaluate({ music }, "a.pause(); ms.playbackState = 'paused'; true")
        wait(0.3)
    }

    private var isChromiumEngine: Bool {
        #if canImport(AircCore)
        return app?.engine is ChromiumEngine
        #else
        return false
        #endif
    }

    /// Polls the noise page's log until it says `ended` that many times (or `timeout` seconds), then hands it on.
    private func waitForLog(_ tabID: String, ended: Int, timeout: Double, _ then: @escaping (String) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            guard let page = c.engineTab(for: tabID) else { return then("no page") }
            page.evaluate("JSON.stringify(log)") { v in
                let log = v as? String ?? "-"
                if log.components(separatedBy: "ended").count - 1 >= ended || Date() > deadline { return then(log) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: poll)
            }
        }
        poll()
    }

    private func noiseEval(_ tabID: String, _ js: String) { c.engineTab(for: tabID)?.evaluate(js) { _ in } }

    /// Runs `js` (a promise or a value) as a click would: Chromium through DevTools' user gesture, WebKit's own
    /// evaluation is one.
    private func gestureEvaluate(_ tab: @escaping () -> String, _ js: String) {
        step { [self] done in
            guard let page = c.engineTab(for: tab()) else { return done() }
            #if canImport(AircCore)
            if let chromium = app?.engine as? ChromiumEngine {
                chromium.devToolsCall("Runtime.evaluate", params: ["expression": js, "userGesture": true, "awaitPromise": true, "returnByValue": true],
                                      in: page) { _, _ in done() }
                return
            }
            #endif
            page.evaluate(js) { _ in done() }
        }
    }
}

extension MediaLibServer {
    static let noisePage = """
    <!doctype html><meta charset="utf-8"><title>Noise</title>
    <body style="font:15px system-ui;padding:24px">Noise fixture: short one-shot sounds only.
    <script>
    var log = [];
    function ping(src){
      var a = new Audio(src);
      a.addEventListener('ended', function(){ log.push('ended ' + src); });
      return a.play().then(function(){ log.push('playing ' + src + ' ' + a.duration); return true; }, function(e){ log.push('refused ' + e); return false; });
    }
    function beep(){
      var c = new AudioContext(), o = c.createOscillator(), g = c.createGain();
      g.gain.value = 0.0001; o.connect(g); g.connect(c.destination);
      o.onended = function(){ log.push('beep ended'); c.close(); };
      o.start(); o.stop(c.currentTime + 1);
      return c.resume().then(function(){ log.push('beep ' + c.state); return true; });
    }
    </script>
    """

    static let trackPage = """
    <!doctype html><meta charset="utf-8"><title>Track</title>
    <body style="font:15px system-ui;padding:24px"><audio id="a" src="/track.wav"></audio>A 30 s track, no metadata.
    <script>
    var a = document.getElementById('a');
    function play(){ return a.play().then(function(){ return true; }); }
    function pause(){ a.pause(); return true; }
    </script>
    """
}
#endif
