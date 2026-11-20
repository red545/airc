// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

#if canImport(AircCore)
/// `--script fairplayvideo` (Chromium, network; docs/design/fairplay-bridge.md step 2). A loopback page plays the part
/// of a listed video site (FairPlayBridge.testVideoOrigin) and plays Axinom's public CMAF test vectors (Apache-licensed
/// test content, https://github.com/Axinom/public-test-vectors) the way a service's player does: MediaSource +
/// SourceBuffer appends of fMP4 byte ranges, and for the protected one EME with FairPlay (server certificate, an skd key
/// request, the page's own POST to Axinom's public licence server with the vector's published test token, `update`).
/// The test token is read from Axinom's README at run time, so none is stored here. No account.
///   - the key system is offered on the listed origin only; the setting off offers nothing;
///   - clear CMAF: samples reach the native renderer, the clock advances, the layer is over the page, pause, seek, the
///     media tray; picture in picture when macOS allows it (needs a key window: FAIL-ENV otherwise);
///   - protected (cbcs, FairPlay): the CDM's request reaches the page, the licence comes back, the key is usable and the
///     protected video plays;
///   - a licence the CDM rejects gives the page a media error and Airc's Safari's-engine offer.
/// Muted (test builds mute the bridge). FAIL-ENV when Axinom isn't reachable.
extension SnapshotRunner {
    func fairPlayVideoScenario() {
        guard app?.engine is ChromiumEngine else { return run { self.note("fairplayvideo: Chromium only") } }
        let tag = "fairplayvideo"
        var server: LocalPageServer?
        var port: UInt16 = 0
        var listed = "", other = ""
        var token = "", licence = "", cert = ""
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: again)
                }
            }
            again()
        }
        func js(_ id: String, _ code: String) { page(id)?.evaluate(code, completion: nil) }
        func num(_ k: String) -> Double { (state[k] as? NSNumber)?.doubleValue ?? -1 }
        func native(_ id: String) -> [String: Any] { page(id).map { FairPlayVideo.shared.testState($0) } ?? [:] }
        func nnum(_ id: String, _ k: String) -> Double { (native(id)[k] as? NSNumber)?.doubleValue ?? -1 }

        // Axinom's published FairPlay test parameters for the cbcs CMAF vector.
        step { done in
            var r = URLRequest(url: URL(string: "https://raw.githubusercontent.com/Axinom/public-test-vectors/master/README.md")!)
            r.timeoutInterval = 20
            URLSession.shared.dataTask(with: r) { data, _, _ in
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if let m = text.range(of: #"protected_1080p_h264_cbcs%2Fmanifest\.m3u8&license=([^&]*)&token=([^&]*)&certUrl=([^&]*)"#, options: .regularExpression) {
                    let parts = text[m].components(separatedBy: "&")
                    func value(_ name: String) -> String {
                        parts.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)).removingPercentEncoding ?? "" } ?? ""
                    }
                    licence = value("license"); token = value("token"); cert = value("certUrl")
                }
                DispatchQueue.main.async(execute: done)
            }.resume()
        }
        step { done in
            let s = LocalPageServer(responses: ["/watch": .init(headers: ["Content-Type": "text/html"], body: Self.fairPlayVideoPage)])
            server = s
            s?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            check(port != 0, "\(tag): loopback server")
            listed = "http://localhost:\(port)"
            other = "http://127.0.0.1:\(port)"
            ProtectedMedia.shared.testHosts = ["localhost"]
            FairPlayBridge.testVideoOrigin = listed
            FairPlayBridge.forcedForTest = true
            check(PageScripts.shared?.contains(FairPlayVideo.part) == true, "\(tag): the video part is in the page script with the setting on")
        }
        wait(0.6)
        var a = "", b = ""
        run { a = open(listed + "/watch"); b = open(other + "/watch") }
        step { done in poll(a, 10, until: { $0["ready"] as? Bool == true }) { poll(b, 10, until: { $0["ready"] as? Bool == true }, done) } }
        step { done in js(a, "probe()"); js(b, "probe()"); poll(b, 5, until: { $0["fps"] != nil }) { poll(a, 5, until: { $0["fps"] != nil }, done) } }
        var probeB: [String: Any] = [:]
        step { done in read(b) { probeB = state; read(a, done) } }
        run { [self] in
            check(!ProtectedMedia.isWebKitPage(page(a)), "\(tag): with the setting on, the listed video site stays in Chromium")
            check(state["fps"] as? String == "granted", "\(tag): the listed origin is offered FairPlay (\(state["fps"] ?? "-"))")
            check(probeB["fps"] as? String != "granted", "\(tag): another origin isn't (\(probeB["fps"] ?? "-"))")
            page(b)?.close()
            c.show(a, focus: true)
        }
        wait(1)

        // Clear CMAF through the MediaSource stand-in.
        run { js(a, "play('clear')") }
        step { done in poll(a, 40, until: { ($0["time"] as? NSNumber)?.doubleValue ?? 0 > 2.5 || has($0, "error") || has($0, "fetchError") }, done) }
        var reachable = true
        run { [self] in
            note("\(tag): clear \((state["log"] as? [String] ?? []).joined(separator: " | "))")
            if has(state, "fetchError") { reachable = false; return note("FAIL-ENV \(tag): Axinom's test vectors unreachable (\(state["fetchError"] ?? ""))") }
            let n = native(a)
            note("\(tag): native \(n)")
            check(nnum(a, "videoSegments") > 0 && n["started"] as? Bool == true && nnum(a, "time") > 2,
                  "\(tag): clear: the fragments reach the native renderer and it plays (\(n["videoSegments"] ?? "-") segments, time \(nnum(a, "time")))")
            check(num("time") > 2.5 && state["paused"] as? Bool == false && (state["events"] as? [String] ?? []).contains("playing"),
                  "\(tag): clear: the page's video plays (time \(num("time")), events \((state["events"] as? [String] ?? []).joined(separator: ",")))")
            check(n["layerShown"] as? Bool == true, "\(tag): the video layer is over the page (\(n["layerFrame"] ?? "-"))")
            check(n["audioMuted"] as? Bool == true, "\(tag): test builds play muted")
        }
        step { [self] done in waitUntil({ MediaLibrary.shared.media?.sessions[a]?.session.playback == .playing }, timeout: 4, then: done) }
        capture("fairplayvideo-clear")
        run { [self] in
            guard reachable else { return }
            check(MediaLibrary.shared.media?.sessions[a]?.session.playback == .playing, "\(tag): the media tray has the video playing")
            js(a, "window.__v.pause()")
        }
        wait(1)
        run { [self] in
            guard reachable else { return }
            check(nnum(a, "rate") == 0, "\(tag): pause reaches the renderer (rate \(nnum(a, "rate")))")
            js(a, "window.__v.currentTime = 12; window.__v.play()")
        }
        step { done in poll(a, 10, until: { ($0["time"] as? NSNumber)?.doubleValue ?? 0 > 12.3 }, done) }
        run { [self] in
            guard reachable else { return }
            check(num("time") >= 12 && nnum(a, "time") >= 12, "\(tag): seek (page \(num("time")), native \(nnum(a, "time")))")
            js(a, "window.__v.requestPictureInPicture().then(() => { __st.pip = 'in'; }, (e) => { __st.pip = e.name; })")
        }
        step { done in poll(a, 5, until: { $0["pip"] != nil }, done) }
        run { [self] in
            guard reachable else { return }
            if state["pip"] as? String == "in" {
                check(native(a)["pip"] as? Bool == true, "\(tag): picture in picture on the sample-buffer layer")
                js(a, "document.exitPictureInPicture()")
            } else {
                note("FAIL-ENV \(tag): picture in picture didn't start (\(state["pip"] ?? "-")); macOS wants a key window")
            }
        }
        wait(1)

        // Protected cbcs CMAF with FairPlay: the page's own licence exchange.
        run { [self] in
            guard reachable else { return }
            if token.isEmpty { note("FAIL-ENV \(tag): Axinom's README had no FairPlay test token") }
            let args = (try? JSONSerialization.data(withJSONObject: [licence, token, cert])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            js(a, "play('protected', \(args))")
        }
        step { done in poll(a, 45, until: { ($0["time"] as? NSNumber)?.doubleValue ?? 0 > 3 || has($0, "error") || has($0, "fetchError") }, done) }
        run { [self] in
            guard reachable, !token.isEmpty else { return }
            note("\(tag): protected \((state["log"] as? [String] ?? []).joined(separator: " | "))")
            let n = native(a)
            note("\(tag): native \(n)")
            check(nnum(a, "requestedKeys") >= 1 && (state["licence"] as? String)?.hasPrefix("200") == true && n["licensed"] as? Bool == true && nnum(a, "keys") >= 1,
                  "\(tag): FairPlay: the CDM's request went to the page, Axinom's licence came back, the key is usable (licence \(state["licence"] ?? "-"), keys \(n["keys"] ?? "-"))")
            check(num("time") > 3 && !has(state, "error") && nnum(a, "time") > 3 && nnum(a, "videoStatus") != 2,
                  "\(tag): the FairPlay-protected video plays in the Chromium page (page \(num("time")), native \(nnum(a, "time")), error \(state["error"] ?? "none"))")
        }
        capture("fairplayvideo-protected")

        // A licence the CDM rejects: media error, and the offer. In a new tab: the first one's session keeps the
        // good key for this key ID (as a real page keeps it for the next title).
        run { FairPlayBridge.lastOffer = nil; page(a)?.close(); a = open(listed + "/watch") }
        step { done in poll(a, 10, until: { $0["ready"] as? Bool == true }, done) }
        run { [self] in
            guard reachable else { return }
            let args = (try? JSONSerialization.data(withJSONObject: [licence, token, cert])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            js(a, "play('badlicence', \(args))")
        }
        step { done in poll(a, 30, until: { has($0, "error") || has($0, "fetchError") }, done) }
        run { [self] in
            guard reachable, !token.isEmpty else { return }
            check(num("errorCode") == 3, "\(tag): a rejected licence gives the page a media error (\(state["error"] ?? "none"))")
            check(FairPlayBridge.lastOffer?.service.hasPrefix("localhost") == true, "\(tag): Airc offers Safari's engine (\(FairPlayBridge.lastOffer?.service ?? "no offer"))")
        }

        // Setting off.
        run { FairPlayBridge.forcedForTest = false }
        wait(0.8)
        run { [self] in
            check(PageScripts.shared?.contains(FairPlayVideo.part) == false, "\(tag): setting off: the video part is gone")
            check(native(a)["session"] as? Bool != true, "\(tag): setting off: no video session left")
            check(ProtectedMedia.shared.engine(for: URL(string: listed + "/watch")) == .webKit, "\(tag): setting off: the listed site opens in WebKit")
            page(a)?.close()
            FairPlayBridge.forcedForTest = nil
            FairPlayBridge.testVideoOrigin = nil
            ProtectedMedia.shared.testHosts = []
            server?.stop()
        }
    }

    /// `--script fairplayua` (Chromium; the engine's per-origin user agent, AircProfile setUserAgent:forOrigin:): with
    /// the setting on, one loopback origin plays Netflix's part and its requests carry Safari's user agent; another
    /// origin (another port) keeps Chromium's; a redirect from that other origin onto the listed one carries Safari's;
    /// the setting off gives the listed origin Chromium's again. Read from the requests the server received.
    func fairPlayUserAgentScenario() {
        guard app?.engine is ChromiumEngine else { return run { self.note("fairplayua: Chromium only") } }
        let tag = "fairplayua"
        guard FairPlayVideo.engineUserAgents else { return run { self.note("FAIL-ENV \(tag): this framework has no setUserAgent:forOrigin: (relink first)") } }
        // Three loopback servers: the listed origin (Netflix's part), its alias (netflix.com's part) and an unrelated site.
        var servers: [LocalPageServer] = []
        var ports: [UInt16] = [0, 0, 0]
        let lock = NSLock()
        var seen: [String: String] = [:]   // "port path" → User-Agent
        func origin(_ i: Int) -> String { "http://127.0.0.1:\(ports[i])" }
        func ua(_ i: Int, _ path: String) -> String { lock.lock(); defer { lock.unlock() }; return seen["\(ports[i]) \(path)"] ?? "" }
        func safari(_ s: String) -> Bool { s.contains("Safari/605.1.15") && s.contains("Version/") && !s.contains("Chrome/") }
        func chrome(_ s: String) -> Bool { s.contains("Chrome/") }
        func start(_ i: Int, _ done: @escaping () -> Void) {
            guard let s = LocalPageServer(responses: [:]) else { return done() }
            s.requestHandler = { r in
                let agent = r.headers.first { $0.key.lowercased() == "user-agent" }?.value ?? ""
                lock.lock(); seen["\(ports[i]) \(r.path)"] = agent; lock.unlock()
                if r.path == "/redirect" { return .init(status: "302 Found", headers: ["Location": "\(origin(0))/after-redirect-\(i)"], body: "") }
                return .init(headers: ["Content-Type": "text/html"], body: "<title>ua</title>ok")
            }
            servers.append(s)
            s.start { p in ports[i] = p ?? 0; done() }
        }
        step { done in start(0) { start(1) { start(2, done) } } }
        run {
            FairPlayBridge.testUserAgentOrigin = origin(0)
            FairPlayBridge.testUserAgentAlias = origin(1)
            FairPlayBridge.forcedForTest = true
        }
        wait(0.6)
        var tabs: [String] = []
        func open(_ url: String) {
            guard let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID) else { return }
            tabs.append(t.id)
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        func visit(_ i: Int, _ path: String, until: (Int, String)? = nil) {
            run { open(origin(i) + path) }
            let (wi, wp) = until ?? (i, path)
            step { done in self.waitUntil({ !ua(wi, wp).isEmpty }, timeout: 8, then: done) }
        }
        visit(0, "/on")
        visit(2, "/other")
        visit(1, "/redirect", until: (0, "/after-redirect-1"))
        visit(2, "/redirect", until: (0, "/after-redirect-2"))
        run { [self] in
            note("\(tag): applied \(FairPlayVideo.appliedUserAgents)")
            check(safari(ua(0, "/on")), "\(tag): a new tab on the listed origin: its request carries Safari's user agent (\(ua(0, "/on")))")
            check(chrome(ua(2, "/other")), "\(tag): another origin keeps Chromium's (\(ua(2, "/other")))")
            check(safari(ua(1, "/redirect")) && safari(ua(0, "/after-redirect-1")),
                  "\(tag): its alias (as netflix.com → www.netflix.com) and the redirect onto it carry Safari's (\(ua(0, "/after-redirect-1")))")
            // A navigation keeps the user agent it started with (Chromium sets it only at the start): a redirect from an
            // unrelated site onto the listed origin isn't overridden. The page script still shows Safari to the page.
            note("NOTE \(tag): redirect from an unrelated site onto the listed origin: \(safari(ua(0, "/after-redirect-2")) ? "Safari's" : "Chromium's") user agent (known limit)")
            FairPlayBridge.forcedForTest = false
        }
        wait(0.6)
        visit(0, "/off")
        run { [self] in
            check(chrome(ua(0, "/off")), "\(tag): setting off: the listed origin gets Chromium's again (\(ua(0, "/off")))")
            for id in tabs { c.engineTab(for: id)?.close() }
            FairPlayBridge.forcedForTest = nil
            FairPlayBridge.testUserAgentOrigin = nil
            FairPlayBridge.testUserAgentAlias = nil
            servers.forEach { $0.stop() }
        }
    }

    /// A service-like player page: MediaSource appends of fMP4 byte ranges, EME FairPlay with the page's own licence POST.
    static let fairPlayVideoPage = #"""
    <!doctype html><title>Fixture video</title><body style="margin:0;background:#222">
    <video id="v" muted playsinline style="width:640px;height:360px;background:#000;display:block"></video><pre id="log" style="color:#ccc"></pre>
    <script>
    var st = window.__st = { ready: true, log: [], events: [] };
    function note(s) { st.log.push(s); document.getElementById('log').textContent = st.log.join('\n'); }
    var cfg = [{ initDataTypes: ['skd', 'sinf', 'cenc'], videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.640015"', robustness: '' }] }];
    async function probe() {
      try { await navigator.requestMediaKeySystemAccess('com.apple.fps', cfg); st.fps = 'granted'; } catch (e) { st.fps = e.name; }
    }
    var base = { clear: 'https://media.axprod.net/TestVectors/Cmaf/clear_1080p_h264/', protected: 'https://media.axprod.net/TestVectors/Cmaf/protected_1080p_h264_cbcs/' };
    async function ranges(dir) {
      var text = await (await fetch(dir + 'video-H264-288-400k.m3u8')).text(), out = { segments: [] }, next = 0, file = '';
      var lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        var l = lines[i].trim(), m;
        if ((m = l.match(/^#EXT-X-MAP:URI="([^"]+)",BYTERANGE="(\d+)@(\d+)"/))) { file = m[1]; out.init = [+m[3], +m[3] + +m[2] - 1]; }
        else if ((m = l.match(/^#EXT-X-KEY:.*URI="(skd:\/\/[^"]+)"/))) out.skd = m[1];
        else if ((m = l.match(/^#EXT-X-BYTERANGE:(\d+)(?:@(\d+))?/))) { var at = m[2] !== undefined ? +m[2] : next; out.segments.push([at, at + +m[1] - 1]); next = at + +m[1]; }
      }
      out.url = dir + file;
      return out;
    }
    async function get(url, r) { return new Uint8Array(await (await fetch(url, { headers: { Range: 'bytes=' + r[0] + '-' + r[1] } })).arrayBuffer()); }
    function waitFor(t, type) { return new Promise(function (res) { t.addEventListener(type, res, { once: true }); }); }
    async function play(mode, drm) {
      st.time = 0; st.error = null; st.errorCode = null; st.events = []; st.licence = null; st.log = [];
      var old = document.getElementById('v'), v = document.createElement('video');
      try { old.pause(); old.removeAttribute('src'); old.load(); } catch (x) {}
      v.id = 'v'; v.muted = true; v.playsInline = true; v.style.cssText = old.style.cssText; old.replaceWith(v); window.__v = v;
      ['loadedmetadata', 'canplay', 'play', 'playing', 'pause', 'seeking', 'seeked', 'ended', 'error', 'waiting'].forEach(function (t) { v.addEventListener(t, function () { st.events.push(t); }); });
      v.addEventListener('error', function () { st.error = v.error && v.error.message; st.errorCode = v.error && v.error.code; });
      var dir = mode === 'clear' ? base.clear : base.protected, r;
      try { r = await ranges(dir); } catch (x) { st.fetchError = String(x); return; }
      try {
        var ms = new MediaSource();
        v.src = URL.createObjectURL(ms);
        await waitFor(ms, 'sourceopen');
        if (mode !== 'clear') {
          var access = await navigator.requestMediaKeySystemAccess('com.apple.fps', cfg);
          var keys = await access.createMediaKeys();
          var c = new Uint8Array(await (await fetch(drm[2])).arrayBuffer());
          await keys.setServerCertificate(c);
          await v.setMediaKeys(keys);
          var session = keys.createSession(), requested = false;
          session.addEventListener('message', async function (m) {
            note('licence request ' + m.message.byteLength + ' bytes');
            if (mode === 'badlicence') { await session.update(new Uint8Array(64)).catch(function () {}); note('sent a bad licence'); return; }
            var res = await fetch(drm[0], { method: 'POST', headers: { 'Content-Type': 'application/octet-stream', 'X-AxDRM-Message': drm[1] }, body: m.message });
            var body = new Uint8Array(await res.arrayBuffer());
            st.licence = res.status + ' ' + body.byteLength; note('licence ' + st.licence);
            var text = new TextDecoder().decode(body).trim();
            var ckc = /^<ckc>/.test(text) ? Uint8Array.from(atob(text.replace(/<\/?ckc>/g, '')), function (ch) { return ch.charCodeAt(0); })
              : /^[A-Za-z0-9+\/=\s]+$/.test(text) && text.length > 32 ? Uint8Array.from(atob(text), function (ch) { return ch.charCodeAt(0); }) : body;
            await session.update(ckc);
            note('update done');
          });
          session.addEventListener('keystatuseschange', function () { var s = []; session.keyStatuses.forEach(function (x) { s.push(x); }); st.keys = s.join(','); });
          // As a Safari MSE player: answer the element's encrypted event (sinf); an skd request only if none comes.
          v.addEventListener('encrypted', function (e) {
            if (requested) return; requested = true; st.encrypted = e.initDataType;
            note('encrypted ' + e.initDataType); session.generateRequest(e.initDataType, e.initData);
          });
          setTimeout(function () {
            if (requested) return; requested = true;
            note('no encrypted event: skd request'); session.generateRequest('skd', new TextEncoder().encode(r.skd));
          }, 6000);
        }
        var sb = ms.addSourceBuffer('video/mp4; codecs="avc1.640015"');
        async function append(bytes) { sb.appendBuffer(bytes); await waitFor(sb, 'updateend'); }
        await append(await get(r.url, r.init));
        var count = Math.min(5, r.segments.length);
        for (var i = 0; i < count; i++) await append(await get(r.url, r.segments[i]));
        note('appended init + ' + count + ' fragments; buffered ' + (sb.buffered.length ? sb.buffered.end(0).toFixed(1) : 0));
        ms.endOfStream();
        await v.play();
        note('play() resolved');
      } catch (x) { st.error = String(x); note('error ' + x); }
    }
    setInterval(function () { var v = window.__v; if (!v) return; st.time = v.currentTime; st.paused = v.paused; st.duration = v.duration; }, 200);
    </script>
    """#
}
#endif
#endif
