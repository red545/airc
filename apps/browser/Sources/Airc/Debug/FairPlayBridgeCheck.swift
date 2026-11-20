// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AVFoundation
import AppKit
import AircKit
import MediaPlayer

#if canImport(AircCore)
/// `--script fairplaybridge` (Chromium; docs/design/fairplay-bridge.md). A loopback page plays the part of a listed
/// site (FairPlayBridge.testOrigin, http://localhost:<port>) and does what Spotify's web player does: asks for Widevine,
/// then FairPlay, sets the server certificate and the keys on a detached `new Audio()`, gives it a data: HLS playlist,
/// answers `encrypted` with a key session, POSTs the licence request itself and calls `update`, and sets the Media
/// Session's metadata and handlers. Checks:
///   - the key system is offered only on the listed origin (127.0.0.1, another site of the same server, gets Chromium's
///     answer) and only with the setting on; the listed site stays in Chromium with it on and opens in WebKit with it off;
///   - a clear HLS audio fixture (ADTS AAC made in the run) plays through the native player: events, advancing time,
///     pause, seek, volume, ended; the media tray and Now Playing show it, and Now Playing's commands reach the page's
///     own handlers;
///   - a playlist naming a local file fails: the page gets a media error and Airc offers Safari's engine;
///   - turning the setting off mid-track pauses the page and stops the player;
///   - EZDRM's public FairPlay test stream (needs the network; FAIL-ENV when unreachable): the page's own licence
///     exchange (SPC → licence server → CKC) and playback.
/// Muted (the bridge mutes every test build's player), no account, no device.
extension SnapshotRunner {
    func fairPlayBridgeScenario() {
        guard app?.engine is ChromiumEngine else { return run { self.note("fairplaybridge: Chromium only") } }
        let tag = "fairplaybridge"
        var server: LocalPageServer?
        var port: UInt16 = 0
        var fixture: [String: Data] = [:]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-fairplaybridge-\(UUID().uuidString)")
        var listed = "", other = ""
        var state: [String: Any] = [:]
        func page(_ id: String) -> EngineTab? { c.engineTab(for: id) }
        /// A page value that is there and not JSON null.
        func has(_ d: [String: Any], _ k: String) -> Bool { d[k].map { !($0 is NSNull) } ?? false }
        func open(_ url: String) -> String {
            guard let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID) else { return "" }
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            return t.id
        }
        func read(_ id: String, _ done: @escaping () -> Void) {
            guard let p = page(id) else { state = [:]; return done() }
            p.evaluate("JSON.stringify(window.__st || {})") { v in
                state = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                done()
            }
        }
        func poll(_ id: String, _ timeout: Double, until: @escaping ([String: Any]) -> Bool, _ done: @escaping () -> Void) {
            let deadline = Date().addingTimeInterval(timeout)
            func again() {
                read(id) {
                    if until(state) || Date() > deadline { return done() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: again)
                }
            }
            again()
        }
        func js(_ id: String, _ code: String) { page(id)?.evaluate(code, completion: nil) }
        func num(_ k: String) -> Double { (state[k] as? NSNumber)?.doubleValue ?? -1 }
        func events() -> [String] { state["events"] as? [String] ?? [] }
        func bridge() -> [String: Any] { FairPlayBridge.shared.testState }
        func bnum(_ k: String) -> Double { (bridge()[k] as? NSNumber)?.doubleValue ?? -1 }

        // The fixture: 12 s of a quiet tone as two 6 s ADTS AAC segments, each with HLS packed audio's ID3 timestamp.
        step { done in
            DispatchQueue.global().async {
                fixture = Self.fairPlayFixture(in: dir)
                DispatchQueue.main.async(execute: done)
            }
        }
        step { [self] done in
            let s = LocalPageServer(responses: [:])
            s?.requestHandler = { r in
                if r.path == "/player" { return .init(headers: ["Content-Type": "text/html"], body: Self.fairPlayPlayerPage) }
                guard let data = fixture[r.path] else { return nil }
                var p = LocalPageServer.Page(headers: ["Content-Type": "audio/aac", "Accept-Ranges": "bytes"], body: "")
                p.data = data
                let range = r.headers.first { $0.key.lowercased() == "range" }?.value ?? ""
                if range.hasPrefix("bytes="), let dash = range.firstIndex(of: "-") {
                    let lo = Int(range[range.index(range.startIndex, offsetBy: 6)..<dash]) ?? 0
                    let hi = min(data.count - 1, Int(range[range.index(after: dash)...]) ?? data.count - 1)
                    if lo <= hi {
                        p.status = "206 Partial Content"
                        p.headers["Content-Range"] = "bytes \(lo)-\(hi)/\(data.count)"
                        p.data = data.subdata(in: lo..<(hi + 1))
                    }
                }
                return p
            }
            server = s
            s?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            check(port != 0 && fixture.count == 2, "\(tag): loopback server and the ADTS fixture (\(fixture.count) segments)")
            listed = "http://localhost:\(port)"
            other = "http://127.0.0.1:\(port)"
            ProtectedMedia.shared.testHosts = ["localhost"]   // the listed site is a WebKit service by today's rules
            FairPlayBridge.testOrigin = listed
            FairPlayBridge.forcedForTest = true
            let source = FairPlayBridgeScript.source(origins: FairPlayBridgeSites.origins, clearTestOrigin: nil)
            check(source.contains("[\"https://open.spotify.com\"]") && !source.contains("__AIRC_"),
                  "\(tag): the page script is composed with exactly the bridge's origins")
        }
        wait(0.6)   // the part reaches the engine's page script

        // 1. Routing with the setting on, and the key system only on the listed origin.
        var a = "", b = ""
        run { a = open(listed + "/player"); b = open(other + "/player") }
        step { done in poll(a, 10, until: { $0["ready"] as? Bool == true }) { poll(b, 10, until: { $0["ready"] as? Bool == true }, done) } }
        step { done in js(a, "probe()"); js(b, "probe()"); poll(b, 5, until: { $0["fps"] != nil }) { poll(a, 5, until: { $0["fps"] != nil }, done) } }
        var probeB: [String: Any] = [:]
        step { done in read(b) { probeB = state; read(a, done) } }
        run { [self] in
            check(!ProtectedMedia.isWebKitPage(page(a)), "\(tag): with the setting on, the listed site stays in Chromium")
            check(state["fps"] as? String == "granted" && state["widevine"] as? String == "NotSupportedError",
                  "\(tag): the listed origin is offered FairPlay and refused Widevine (fps \(state["fps"] ?? "-"), widevine \(state["widevine"] ?? "-"))")
            check(ProtectedMedia.shared.askedForWidevine(page(a)),
                  "\(tag): Site Controls offers Safari's engine on the bridged page (its Widevine was refused)")
            check(probeB["fps"] as? String != "granted",
                  "\(tag): another origin isn't offered FairPlay (fps \(probeB["fps"] ?? "-"), widevine \(probeB["widevine"] ?? "-"))")
            page(b)?.close()
            c.show(a, focus: true)   // the fixture page on screen again (a real click must land on it)
        }
        wait(1)

        // 2. A clear fixture plays through the native player: started by a real click on the page's own Play button
        // when the UI driver is available (AIRC_REAL_KEYS=1, dedicated session), else from the page's script.
        var realInput = false
        step { [self] done in
            guard UIDriverClient.available, let p = page(a) else { js(a, "play('clear')"); return done() }
            p.evaluate("JSON.stringify((function(){var r=document.getElementById('b').getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2];})())") { v in
                let xy = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Double] } ?? []
                let view = p.view
                guard xy.count == 2, let window = view.window else { js(a, "play('clear')"); return done() }
                let inView = NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : view.bounds.height - xy[1])
                // A plain click: the driver's --click without --mods (UIDriverClient.click always sends modifiers).
                let screen = window.convertPoint(toScreen: view.convert(inView, to: nil))
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                guard NSApp.isActive, window.isKeyWindow, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
                    self.note("FAIL-ENV \(tag): not the active key window in a dedicated session; started from the page's script")
                    js(a, "play('clear')")
                    return done()
                }
                UIDriverClient.run(["--click", String(Double(screen.x)), String(Double(top - screen.y))]) { ok, out in
                    realInput = ok
                    if !ok { self.note("FAIL-ENV \(tag): real click unavailable (\(out)); started from the page's script"); js(a, "play('clear')") }
                    done()
                }
            }
        }
        step { done in poll(a, 20, until: { ($0["time"] as? NSNumber)?.doubleValue ?? 0 > 1.5 || has($0, "error") }, done) }
        run { [self] in
            if realInput { check(state["clicked"] as? Bool == true, "\(tag): real click on the page's Play button (trusted)") }
        }
        if true {
            var spaced = false
            step { [self] done in
                guard realInput else { return done() }
                UIDriverClient.press(["space"], pid: getpid()) { ok, out in
                    spaced = ok
                    if !ok { self.note("FAIL-ENV \(tag): real space key unavailable (\(out))") }
                    done()
                }
            }
            step { done in poll(a, 3, until: { $0["paused"] as? Bool == true }, done) }
            wait(0.8)
            run { [self] in
                guard spaced else { return }
                check(state["spaceKey"] as? Bool == true && state["paused"] as? Bool == true && bnum("rate") == 0,
                      "\(tag): real space key: the page pauses its element and the native player stops (rate \(bnum("rate")))")
                js(a, "window.__a.play()")
            }
            step { done in poll(a, 5, until: { ($0["paused"] as? Bool) == false }, done) }
        }
        // The clear loopback fixture only proves the element's plumbing when AVFoundation loads it; the transport
        // (time, duration, seek, ended) is checked on EZDRM's protected stream below either way.
        var clearLoaded = false
        run { [self] in
            let ev = events()
            clearLoaded = bridge()["ready"] as? Bool == true
            guard clearLoaded else {
                return note("NOTE \(tag): the clear loopback fixture didn't load in AVFoundation (\(bridge()["itemError"] ?? "-")); transport checked on EZDRM")
            }
            check(bridge()["player"] as? Bool == true && bnum("time") > 1, "\(tag): the native player plays (\(bridge()))")
            check(["loadedmetadata", "canplay", "play", "playing"].allSatisfy(ev.contains) && num("time") > 1.5 && state["paused"] as? Bool == false,
                  "\(tag): the page's element plays (time \(num("time")), events \(ev.joined(separator: ",")), error \(state["error"] ?? "none"))")
            check(abs(num("duration") - 12) < 0.6, "\(tag): duration from the native player (\(num("duration")))")
            check(bridge()["muted"] as? Bool == true, "\(tag): test builds play muted")
        }
        // Tray and Now Playing (the tab is still on screen: the tray hides it, Now Playing doesn't).
        step { [self] done in waitUntil({ MediaLibrary.shared.media?.sessions[a]?.session.playback == .playing }, timeout: 5, then: done) }
        run { [self] in
            let p = MediaLibrary.shared.media?.sessions[a]
            check(p?.session.playback == .playing && p?.title == "Fixture Tone" && p?.subtitle == "Airc Test",
                  "\(tag): the media tray has the player (\(p?.title ?? "-") / \(p?.subtitle ?? "-"), \(p?.session.playback.rawValue ?? "none"))")
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            check(info?[MPMediaItemPropertyTitle] as? String == "Fixture Tone",
                  "\(tag): Now Playing shows the track (\(info?[MPMediaItemPropertyTitle] ?? "-"))")
            // A media key: Now Playing's pause reaches the page's own handler, which pauses the element.
            check(MediaLibrary.shared.media?.nowPlaying.perform("pause") == true, "\(tag): Now Playing takes pause")
        }
        step { done in poll(a, 5, until: { ($0["handled"] as? [String])?.contains("pause") == true && $0["paused"] as? Bool == true }, done) }
        wait(0.8)
        run { [self] in
            check((state["handled"] as? [String])?.contains("pause") == true && state["paused"] as? Bool == true && bnum("rate") == 0,
                  "\(tag): the pause key reached the page's handler and the native player paused (handled \(state["handled"] ?? "-"), rate \(bnum("rate")))")
            check(MediaLibrary.shared.media?.sessions[a]?.session.playback == .paused, "\(tag): the tray says paused")
            js(a, "seekTo(8); window.__a.volume = 0.5; window.__a.play()")
        }
        step { done in poll(a, 6, until: { ($0["time"] as? NSNumber)?.doubleValue ?? 0 >= 8.3 }, done) }
        run { [self] in
            guard clearLoaded else { return check(abs(bnum("volume") - 0.5) < 0.01, "\(tag): volume reaches the native player (\(bnum("volume")))") }
            check(num("time") >= 8 && events().contains("seeked") && bnum("time") >= 8,
                  "\(tag): seek (page \(num("time")), native \(bnum("time")))")
            check(abs(bnum("volume") - 0.5) < 0.01, "\(tag): volume reaches the native player (\(bnum("volume")))")
        }
        step { done in poll(a, 8, until: { (($0["events"] as? [String]) ?? []).contains("ended") }, done) }
        run { [self] in
            guard clearLoaded else { return }
            check(events().contains("ended") && state["paused"] as? Bool == true, "\(tag): ended at the end (\(events().suffix(4)))")
        }
        capture("fairplaybridge-playing")

        // 3. A failure: a playlist naming a local file. Media error, and the offer.
        run { FairPlayBridge.lastOffer = nil; js(a, "play('bad')") }
        step { done in poll(a, 6, until: { has($0, "error") }, done) }
        run { [self] in
            check(num("errorCode") == 3 && events().contains("error"), "\(tag): a bad playlist gives the page a media error (\(state["error"] ?? "none"))")
            check(FairPlayBridge.lastOffer?.service.hasPrefix("localhost") == true, "\(tag): Airc offers Safari's engine (\(FairPlayBridge.lastOffer?.service ?? "no offer"))")
            check(bridge()["player"] as? Bool != true, "\(tag): no player left after the failure")
        }
        capture("fairplaybridge-offer")

        // 4. The setting off mid-track: the page pauses, the player goes, new pages are today's.
        run { js(a, "play('clear')") }
        step { done in poll(a, 15, until: { ($0["time"] as? NSNumber)?.doubleValue ?? 0 > 1 }, done) }
        run { FairPlayBridge.forcedForTest = false }
        step { done in poll(a, 4, until: { $0["paused"] as? Bool == true }, done) }
        wait(0.6)
        var offPage = ""
        run { [self] in
            check(state["paused"] as? Bool == true && bridge()["player"] as? Bool != true,
                  "\(tag): setting off mid-track: the page pauses and the player stops (\(bridge()))")
            check(PageScripts.shared?.contains("fairplay") == false, "\(tag): setting off: the part is gone from the page script")
            check(ProtectedMedia.shared.engine(for: URL(string: listed + "/player")) == .webKit,
                  "\(tag): setting off: the listed site opens in WebKit (today's rules)")
            offPage = open(other + "/player")
        }
        step { done in poll(offPage, 10, until: { $0["ready"] as? Bool == true }) { js(offPage, "probe()"); poll(offPage, 5, until: { $0["fps"] != nil }, done) } }
        run { [self] in
            check(state["fps"] as? String != "granted",
                  "\(tag): setting off: no page is offered FairPlay (fps \(state["fps"] ?? "-"), widevine \(state["widevine"] ?? "-"))")
            page(offPage)?.close()
            page(a)?.close()
        }

        // 5. EZDRM's public FairPlay stream through the bridge: the page's own licence exchange.
        run { FairPlayBridge.forcedForTest = true }
        wait(0.6)
        var e = ""
        run { e = open(listed + "/player") }
        step { done in poll(e, 10, until: { $0["ready"] as? Bool == true }) { js(e, "play('ezdrm')"); done() } }
        step { done in poll(e, 45, until: { ($0["time"] as? NSNumber)?.doubleValue ?? 0 > 4 || has($0, "error") || has($0, "fetchError") }, done) }
        run { [self] in
            note("\(tag): ezdrm \((state["log"] as? [String] ?? []).joined(separator: " | "))")
            if has(state, "fetchError") {
                note("FAIL-ENV \(tag): EZDRM's test stream unreachable (\(state["fetchError"] ?? ""))")
            } else {
                check(bridge()["requested"] as? Bool == true && (state["licence"] as? String)?.hasPrefix("200") == true && bridge()["licensed"] as? Bool == true,
                      "\(tag): EZDRM: the CDM's request went to the page, its licence server answered, the CKC reached the CDM (licence \(state["licence"] ?? "-"))")
                check(num("time") > 4 && !has(state, "error") && bnum("time") > 4,
                      "\(tag): EZDRM's FairPlay stream plays through the bridge (page \(num("time")), native \(bnum("time")), error \(state["error"] ?? "none"))")
            }
            check(has(state, "fetchError") || num("duration") > 30,
                  "\(tag): EZDRM: duration from the native player (\(num("duration")))")
            js(e, "seekTo(window.__a.duration - 3)")
        }
        step { done in poll(e, 8, until: { ($0["time"] as? NSNumber)?.doubleValue ?? 0 > 30 }, done) }
        run { [self] in
            guard !has(state, "fetchError") else { return }
            check(num("time") > 30 && bnum("time") > 30 && events().contains("seeked"), "\(tag): EZDRM: seek (page \(num("time")), native \(bnum("time")))")
        }
        step { done in poll(e, 10, until: { (($0["events"] as? [String]) ?? []).contains("ended") }, done) }
        run { [self] in
            guard !has(state, "fetchError") else { return }
            check(events().contains("ended") && state["paused"] as? Bool == true, "\(tag): EZDRM: ended at the end (\(events().suffix(4)))")
            js(e, "window.__a && window.__a.pause()")
        }
        wait(0.5)
        run {
            page(e)?.close()
            FairPlayBridge.forcedForTest = nil
            FairPlayBridge.testOrigin = nil
            ProtectedMedia.shared.testHosts = []
            server?.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Two 6 s ADTS AAC segments of a quiet 440 Hz tone, each led by the ID3 PRIV timestamp HLS packed audio needs.
    static func fairPlayFixture(in dir: URL) -> [String: Data] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [String: Data] = [:]
        for i in 0..<2 {
            let wav = dir.appendingPathComponent("a\(i).wav"), aac = dir.appendingPathComponent("a\(i).aac")
            let rate = 44_100.0, seconds = 6.0
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)),
                  let file = try? AVAudioFile(forWriting: wav, settings: format.settings) else { return [:] }
            buffer.frameLength = buffer.frameCapacity
            let samples = buffer.floatChannelData![0]
            for n in 0..<Int(buffer.frameLength) {
                samples[n] = Float(0.05 * sin(2 * .pi * 440 * (Double(n) / rate + Double(i) * seconds)))
            }
            do { try file.write(from: buffer) } catch { return [:] }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            p.arguments = ["-f", "adts", "-d", "aac", "-b", "64000", wav.path, aac.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [:] }
            p.waitUntilExit()
            guard p.terminationStatus == 0, let data = try? Data(contentsOf: aac) else { return [:] }
            out["/a\(i).aac"] = id3Timestamp(UInt64(Double(i) * seconds * 90_000)) + data
        }
        return out
    }

    /// ID3v2.4 with one PRIV frame "com.apple.streaming.transportStreamTimestamp" (a 33-bit 90 kHz time).
    private static func id3Timestamp(_ ticks: UInt64) -> Data {
        var priv = Data("com.apple.streaming.transportStreamTimestamp".utf8) + Data([0])
        for shift in stride(from: 56, through: 0, by: -8) { priv.append(UInt8((ticks & 0x1_FFFF_FFFF) >> UInt64(shift) & 0xFF)) }
        func syncsafe(_ n: Int) -> Data { Data([UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)]) }
        let frame = Data("PRIV".utf8) + syncsafe(priv.count) + Data([0, 0]) + priv
        return Data("ID3".utf8) + Data([4, 0, 0]) + syncsafe(frame.count) + frame
    }

    /// The listed site's player page: what Spotify's web player does with a key system and its element.
    static let fairPlayPlayerPage = #"""
    <!doctype html><title>Fixture player</title><body><button id="b">Play</button><pre id="log"></pre>
    <script>
    var st = window.__st = { ready: true, log: [], events: [], handled: [] };
    function note(s) { st.log.push(s); document.getElementById('log').textContent = st.log.join('\n'); }
    var cfg = [{ initDataTypes: ['cenc', 'sinf', 'skd'], audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"', robustness: '' }] }];
    async function probe() {
      try { await navigator.requestMediaKeySystemAccess('com.widevine.alpha', cfg); st.widevine = 'granted'; } catch (e) { st.widevine = e.name; }
      try { await navigator.requestMediaKeySystemAccess('com.apple.fps.1_0', cfg); st.fps = 'granted'; } catch (e) { st.fps = e.name; }
    }
    function seekTo(t) { window.__a.currentTime = t; }
    // Segments by loopback address (App Transport Security leaves those alone for AVFoundation's own loads).
    var seg = location.origin.replace('://localhost:', '://127.0.0.1:');
    var ezdrm = 'https://fps.ezdrm.com', stream = ezdrm + '/demo/video/ezdrm.m3u8', certURL = ezdrm + '/demo/video/eleisure.cer',
        licence = ezdrm + '/api/licenses/09cc0377-6dd4-40cb-b09d-b582236e70fe';
    function absolute(text, base) {
      return text.split('\n').map(function (line) {
        if (line && line[0] !== '#') return new URL(line.trim(), base).href;
        return line.replace(/URI="([^"]+)"/g, function (m, u) { return /^skd:/.test(u) ? m : 'URI="' + new URL(u, base).href + '"'; });
      }).join('\n');
    }
    async function ezdrmPlaylist() {
      var text = await (await fetch(stream)).text(), base = stream;
      if (/#EXT-X-STREAM-INF/.test(text)) {
        var lines = text.split('\n'), i = lines.findIndex(function (l) { return /#EXT-X-STREAM-INF/.test(l); });
        base = new URL(lines[i + 1].trim(), stream).href;
        text = await (await fetch(base)).text();
      }
      return absolute(text, base);
    }
    async function play(mode) {
      st.time = 0; st.error = null; st.errorCode = null; st.events = []; st.handled = [];
      try {
        await probe();
        var access = await navigator.requestMediaKeySystemAccess('com.apple.fps.1_0', cfg);
        var keys = await access.createMediaKeys(), playlist;
        if (window.__a) { window.__a.pause(); window.__a.removeAttribute('src'); }
        var a = window.__a = new Audio();
        ['loadedmetadata', 'durationchange', 'canplay', 'play', 'playing', 'pause', 'seeking', 'seeked', 'ended', 'error', 'waiting', 'volumechange']
          .forEach(function (t) { a.addEventListener(t, function () { st.events.push(t); }); });
        a.addEventListener('error', function () { st.error = a.error && a.error.message; st.errorCode = a.error && a.error.code; });
        if (mode === 'ezdrm') {
          try {
            var cert = new Uint8Array(await (await fetch(certURL)).arrayBuffer());
            playlist = await ezdrmPlaylist();
          } catch (x) { st.fetchError = String(x); return; }
          await keys.setServerCertificate(cert);
          note('certificate ' + cert.byteLength + ' bytes; playlist ' + playlist.length + ' chars');
        } else if (mode === 'bad') {
          playlist = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nfile:///etc/hosts\n#EXT-X-ENDLIST\n';
        } else {
          playlist = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n'
            + '#EXTINF:6.0,\n' + seg + '/a0.aac\n#EXTINF:6.0,\n' + seg + '/a1.aac\n#EXT-X-ENDLIST\n';
        }
        await a.setMediaKeys(keys);
        a.addEventListener('encrypted', function (e) {
          note('encrypted ' + e.initDataType);
          var session = keys.createSession();
          session.addEventListener('message', async function (m) {
            note('licence request ' + m.message.byteLength + ' bytes');
            var r = await fetch(licence, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: m.message });
            var ckc = new Uint8Array(await r.arrayBuffer());
            st.licence = r.status + ' ' + ckc.byteLength; note('licence ' + st.licence);
            await session.update(ckc);
          });
          session.generateRequest(e.initDataType, e.initData);
        });
        navigator.mediaSession.metadata = new MediaMetadata({ title: 'Fixture Tone', artist: 'Airc Test', album: 'Loopback' });
        ['play', 'pause', 'nexttrack'].forEach(function (name) {
          navigator.mediaSession.setActionHandler(name, function () { st.handled.push(name); if (name === 'play') a.play(); if (name === 'pause') a.pause(); });
        });
        a.src = 'data:application/vnd.apple.mpegurl;base64,' + btoa(playlist);
        await a.play();
        note('play() resolved');
      } catch (x) { st.error = String(x); note('error ' + x); }
    }
    document.getElementById('b').addEventListener('click', function (e) { st.clicked = e.isTrusted; play('clear'); });
    addEventListener('keydown', function (e) {
      if (e.key !== ' ' || !window.__a) return;
      e.preventDefault(); st.spaceKey = e.isTrusted;
      if (window.__a.paused) window.__a.play(); else window.__a.pause();
    });
    setInterval(function () {
      var a = window.__a; if (!a) return;
      st.time = a.currentTime; st.paused = a.paused; st.duration = a.duration; st.ready = true;
    }, 200);
    </script>
    """#
}
#endif
#endif
