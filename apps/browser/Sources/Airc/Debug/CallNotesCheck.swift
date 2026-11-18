// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import Network
import WebKit

/// `--script callnotes` (both engines): Settings › Calendar › "Start Granola notes when a call starts" (Call/CallNotes.swift).
/// Call pages on meet.jit.si and whereby.com come from one loopback fixture (Chromium:
/// `--host-resolver-rules=MAP meet.jit.si 127.0.0.1, MAP whereby.com 127.0.0.1 --disable-features=HttpsUpgrades`;
/// WebKit: the profile's CONNECT proxy for those two hosts). The pages run a canvas and a silent WebAudio stream, like a
/// call; the microphone is the engine's word, set through CallNotes.testMicrophone and SiteControlsCenter's notice (no
/// getUserMedia in tests, common.md 2026-11-06).
/// Granola is a fake app (artifacts/granola/fake-handler, no URL types, so LaunchServices never picks it for `granola:`)
/// named by AIRC_CALLNOTES_TEST_HANDLER; Airc opens it by path, never through the system's `granola:` handler (a real
/// Granola may be installed on the test Mac and must never get a link). It appends each URL to
/// $TMPDIR/airc-fake-granola/received.log. With it: off → nothing; on → exactly one URL; repeat notices, a rejoin and a
/// reload within five minutes → none; a private window → none; another call → one more. Every open must name the fake.
/// With AIRC_CALLNOTES_TEST_HANDLER pointing at no app: "not installed", nothing opens (the Settings row's condition).
/// Without the variable the whole check SKIPs.
extension SnapshotRunner {
    func callNotesScenario() {
        guard let fake = CallNotes.testHandler else {
            run { [self] in skip("callnotes: needs AIRC_CALLNOTES_TEST_HANDLER (never the system's granola: handler)") }
            return
        }
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ s: String) -> String { "callnotes \(engine): " + s }
        let hosts = ["meet.jit.si", "whereby.com"]
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("airc-fake-granola/received.log")
        var server: CallNotesFixture?
        var port: UInt16 = 0
        var originalSetting = false
        var tabs: [String] = []
        var privateWindow: PrivateWindowController?
        var privatePage: EngineTab?
        let installed = CallNotes.granolaApp != nil
        func received() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        var openedBefore = 0, receivedBefore = 0
        func url(_ host: String, _ room: String) -> URL { URL(string: "http://\(host):\(port)/\(room)")! }
        func proxy(_ profile: EngineProfile?) {
            guard let profile = profile as? WebKitProfile, let p = NWEndpoint.Port(rawValue: port) else { return }
            var config = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: p))
            config.matchDomains = hosts
            config.allowFailover = false
            profile.dataStore.proxyConfigurations = [config]
        }
        func mic(_ page: EngineTab?, _ on: Bool) {
            guard let page else { return }
            CallNotes.testMicrophone[ObjectIdentifier(page)] = on
            SiteControlsCenter.shared?.pageChanged(page)
        }
        func mark() { openedBefore = CallNotes.shared.opened.count; receivedBefore = received().count }
        /// After a moment for the handler to launch and write: what Airc opened, and what the fake handler received.
        func expect(_ n: Int, _ what: String) {
            step { [self] done in
                waitUntil({ installed && n > 0 && self.receivedNew(log, receivedBefore) >= n }, timeout: n > 0 ? 15 : 4) {
                    let opened = CallNotes.shared.opened.count - openedBefore
                    let got = Array(received().dropFirst(receivedBefore))
                    let urlsOK = got.allSatisfy { $0 == CallNotesTrigger.granolaURL.absoluteString }
                    let elsewhere = CallNotes.shared.opened.filter { $0.app?.standardizedFileURL != fake.standardizedFileURL }
                    self.check(elsewhere.isEmpty, label("\(what): every open went to the fake app by path (elsewhere: \(elsewhere.count))"))
                    if installed {
                        self.check(opened == n && got.count == n && urlsOK,
                                   label("\(what): \(n) URL(s) expected; Airc opened \(opened), the fake Granola got \(got.count) \(got)"))
                    } else {
                        self.check(opened == 0, label("\(what), no granola: handler: Airc opened \(opened) (expected 0)"))
                    }
                    done()
                }
            }
        }
        func load(_ host: String, _ room: String) -> () -> EngineTab? {
            var id = ""
            run { [self] in
                if let t = try? c.store.openTab(url: url(host, room).absoluteString, inSpace: c.currentSpaceID, title: "call") {
                    id = t.id; tabs.append(t.id)
                    c.show(t.id, focus: true)
                }
            }
            let page = { self.c.engineTab(for: id) }
            step { [self] done in
                // WebKit upgrades well-known hosts to https by itself (upgradeKnownHostsToHTTPS), which the loopback fixture
                // can't serve; the trigger reads the tab's address and the engine's microphone, not the page.
                // (its https load to the fixture's port never finishes, so only the address counts).
                let upgraded = { engine == "WebKit" && page()?.url?.scheme == "https" }
                waitUntil({ page()?.url?.host == host && ((page()?.isLoading == false && page()?.title == "Call fixture") || upgraded()) },
                          timeout: 15) {
                    self.check(page()?.url?.host == host && (page()?.title == "Call fixture" || upgraded()),
                               label("call tab on \(host)/\(room)\(upgraded() ? " (WebKit upgraded it to https; fixture page not shown)" : " loads") "
                                     + "(\(page()?.url?.absoluteString ?? "none"))"))
                    done()
                }
            }
            return page
        }

        step { [self] done in
            originalSetting = app?.settings.values.granolaCallNotes ?? false
            app?.settings.values.granolaCallNotes = false
            check(CallNotes.granolaApp == (installed ? fake : nil),
                  label("test handler \(fake.lastPathComponent) \(installed ? "present" : "absent (Granola counts as not installed)")"))
            server = try? CallNotesFixture()
            guard let server else { check(false, label("fixture server starts")); return done() }
            server.start { value in
                port = value
                self.c.profiles.whenLoaded(self.c.store.selectedSpace.profileID, { loaded in proxy(loaded); done() },
                                           failed: { self.check(false, label("profile loads")); done() })
            }
        }
        if engine == "Chromium" {
            run { [self] in
                let mapped = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--host-resolver-rules=") && $0.contains("whereby.com") }
                check(mapped, label("Chromium launched with --host-resolver-rules for meet.jit.si and whereby.com"))
            }
        }

        // 1. Off: a call's microphone opens nothing.
        let offCall = load("meet.jit.si", "AircOffRoom")
        run { mark(); mic(offCall(), true) }
        expect(0, "setting off, microphone on")
        run { mic(offCall(), false) }

        // 2. On: exactly one note when the microphone starts; repeat notices while it stays on ask nothing.
        run { [self] in app?.settings.values.granolaCallNotes = true }
        let call = load("whereby.com", "airc-standup")
        run { mark(); mic(call(), true) }
        expect(installed ? 1 : 0, "setting on, microphone on")
        run { mark(); mic(call(), true); mic(call(), true) }
        expect(0, "the same call's later notices")

        // 3. Rejoin within the window: leave (microphone off), back on; then a reload and on again.
        run { mark(); mic(call(), false) }
        run { mic(call(), true) }
        expect(0, "rejoin within five minutes")
        run { [self] in mark(); mic(call(), false); call()?.reload() }
        step { [self] done in waitUntil({ call()?.isLoading == false && call()?.title == "Call fixture" }, timeout: 10) { done() } }
        run { mic(call(), true) }
        expect(0, "reloaded and rejoined within five minutes")
        run { mic(call(), false) }

        // 4. A private window: nothing.
        run { [self] in
            guard let app else { return }
            PrivateBrowsing.shared.open(app: app) { w in privateWindow = w }
        }
        step { [self] done in waitUntil({ privateWindow != nil }, timeout: 8) { done() } }
        run {
            proxy(privateWindow?.profile)
            privatePage = privateWindow?.openPage(url("meet.jit.si", "AircPrivateRoom"))
        }
        step { [self] done in waitUntil({ privatePage?.isLoading == false && (privatePage?.title == "Call fixture" || privatePage?.url?.scheme == "https") }, timeout: 15) {
            self.check(privatePage?.url?.host == "meet.jit.si" && privatePage.map(CallNotes.isPrivate) == true,
                       label("private call page loads and is private (\(privatePage?.url?.absoluteString ?? "none"))"))
            done()
        } }
        run { mark(); mic(privatePage, true) }
        expect(0, "private window, microphone on")
        run { mic(privatePage, false); privateWindow?.closeWindow() }

        // 5. Another call in a normal window: one more.
        let second = load("meet.jit.si", "AircSecondRoom")
        run { mark(); mic(second(), true) }
        expect(installed ? 1 : 0, "another call, microphone on")
        run { mic(second(), false) }
        capture("callnotes-\(engine.lowercased())")

        run { [self] in
            app?.settings.values.granolaCallNotes = originalSetting
            CallNotes.testMicrophone = [:]
            for t in tabs { _ = try? c.store.closeTab(t) }
            if let profile = c.profiles.engineProfile(for: c.store.selectedSpace.profileID) as? WebKitProfile {
                profile.dataStore.proxyConfigurations = []
            }
            server?.stop()
        }
    }

    fileprivate func receivedNew(_ log: URL, _ before: Int) -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count - before
    }
}

/// Loopback HTTP fixture and CONNECT endpoint for WebKit's per-profile proxy. Every path is a call page.
private final class CallNotesFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "airc.callnotes.fixture")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }
    func start(_ ready: @escaping (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port { DispatchQueue.main.async { ready(port.rawValue) } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, Data())
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }

    /// A call-like page: a moving canvas stream in a <video> and a silent WebAudio stream; no camera or microphone.
    static let page = """
        <!doctype html><title>Call fixture</title><style>body{font:16px -apple-system;margin:24px}video{width:320px;background:#123}</style>
        <h1>Call fixture</h1><video autoplay muted playsinline></video><script>
        const c=document.createElement('canvas');c.width=320;c.height=180;const g=c.getContext('2d');let f=0;
        setInterval(()=>{g.fillStyle='#'+((f++*997)%4096).toString(16).padStart(3,'0');g.fillRect(0,0,320,180)},100);
        const s=c.captureStream(10);try{const a=new AudioContext(),o=a.createOscillator(),v=a.createGain();v.gain.value=0;
        const d=a.createMediaStreamDestination();o.connect(v).connect(d);o.start();s.addTrack(d.stream.getAudioTracks()[0])}catch(e){}
        document.querySelector('video').srcObject=s;</script>
        """

    private func receive(_ connection: NWConnection, _ prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var bytes = prefix
            bytes.append(data ?? Data())
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || bytes.count > 65536 { connection.cancel() } else { self.receive(connection, bytes) }
                return
            }
            let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
            if head.hasPrefix("CONNECT ") {
                connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    self.receive(connection, Data(bytes[end.upperBound...]))
                })
                return
            }
            let payload = Data(Self.page.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
#endif
