// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script keeploaded` (both engines; MEM-3's exemption, Browser/TabUnloading.swift), on loopback pages with a 2 s
/// unload timeout and "localhost" on the never-unload list (AircKit's KeepLoadedSites, as a test entry):
///   - a pinned tab and a Favorite on the listed host stay loaded; a pinned tab on an unlisted host (127.0.0.1) and a
///     Today tab on the listed host unload;
///   - with Settings → General → "Keep chat and mail sites loaded" off, the listed pinned tab and Favorite unload too;
///   - Chromium build: the same for WebKit pages (both hosts set to play in Safari's engine);
///   - WebKit pages: a Today tab on the unlisted host playing through an `Audio` element that isn't in the document
///     stays loaded and unloads once paused; Web Audio separately covers the engine-only signal.
/// Chromium pressure check also requires --airc-data-dir=<same folder as --data-dir> (scratch-only engine gate).
/// No account, no camera, microphone or screen.
extension SnapshotRunner {
    func keepLoadedScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        var server: LocalPageServer?
        var port: UInt16 = 0
        var space = ""
        func url(_ host: String, _ path: String) -> String { "http://\(host):\(port)\(path)" }
        let page = { (title: String) in "<!doctype html><title>\(title)</title><h1>\(title)</h1>" }
        // A looping second of an almost silent tone (amplitude 2 of 32767, at a tenth of the volume) through an Audio
        // element never added to the document: the media bridge tracks it through play(), not document events.
        let detached = { (title: String) in page(title) + """
            <script>
            (function(){
              var rate = 8000, n = rate, buf = new ArrayBuffer(44 + n * 2), v = new DataView(buf);
              function s(o, t){ for (var i = 0; i < t.length; i++) v.setUint8(o + i, t.charCodeAt(i)); }
              s(0, 'RIFF'); v.setUint32(4, 36 + n * 2, true); s(8, 'WAVEfmt '); v.setUint32(16, 16, true);
              v.setUint16(20, 1, true); v.setUint16(22, 1, true); v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true);
              v.setUint16(32, 2, true); v.setUint16(34, 16, true); s(36, 'data'); v.setUint32(40, n * 2, true);
              for (var i = 0; i < n; i++) v.setInt16(44 + i * 2, Math.round(2 * Math.sin(i / rate * 2 * Math.PI * 440)), true);
              var a = new Audio(URL.createObjectURL(new Blob([buf], {type: 'audio/wav'})));
              a.loop = true; a.volume = 0.1;
              window.__detached = a; window.__played = 'pending';
              a.play().then(function(){ window.__played = 'playing'; }, function(e){ window.__played = 'refused: ' + e.name; });
            })();
            </script>
            """ }

        step { [self] done in
            var pages: [String: String] = [:]
            for p in ["chat", "plain", "mail", "today", "shown"] {
                for n in ["", "2"] { pages["/\(p)\(n)"] = page(p + n) }
            }
            for n in ["", "2"] {
                pages["/detached\(n)"] = detached("detached" + n)
                // Web Audio has no HTML media element for the bridge to report. No input devices.
                pages["/webaudio\(n)"] = page("webaudio" + n) + """
                    <script>
                    // Start from evaluation while shown, not a background document's load script.
                    window.__startAudio = function() {
                      window.__audio = new AudioContext();
                      window.__tone = __audio.createOscillator(); window.__gain = __audio.createGain();
                      __gain.gain.value = 0.00001;
                      __tone.connect(__gain).connect(__audio.destination); __tone.start(); __audio.resume();
                    };
                    </script>
                    """
            }
            server = LocalPageServer(pages: pages)
            guard let server else { check(false, "keep loaded: the loopback server starts"); return done() }
            server.start { p in
                if let p { port = p } else { self.check(false, "keep loaded: the loopback server starts") }
                done()
            }
        }
        run { [self] in
            WindowController.keepLoadedTestSites = ["localhost"]
            app?.settings.values.keepChatSitesLoaded = true
            // Leaving a tab must not put anything in picture in picture (it would keep the page).
            app?.settings.values.pipAutomatic = false
            c.applyPictureInPictureSettings()
            space = c.currentSpaceID
            check(app?.settings.values.keepChatSitesLoaded == true && Values().keepChatSitesLoaded,
                  "keep loaded: \"Keep chat and mail sites loaded\" is on by default")
        }

        /// One round: the four tabs, each shown once, then a fifth shown; after the timeout, which pages are left.
        func round(_ label: String, suffix: String, webKit: Bool) {
            var ids: [String: String] = [:]
            var audioReady = false
            var audioEvidence: [[String: Any]] = []
            func recordAudio(_ page: WebKitTab, _ phase: String, completion: @escaping (Double?) -> Void) {
                page.evaluate("({state:__audio.state,time:__audio.currentTime,gain:__gain.gain.value})") { [self] value in
                    var sample = value as? [String: Any] ?? [:]
                    let time = sample["state"] as? String == "running" ? sample["time"] as? Double : nil
                    sample["phase"] = phase
                    sample["engine_audio"] = page.engineReportsAudio ?? false
                    sample["script_audio"] = page.isAudible
                    scrollRestoreSample(page) { window in
                        sample["window"] = window
                        audioEvidence.append(sample)
                        if let data = try? JSONSerialization.data(withJSONObject: audioEvidence, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: self.dir.appendingPathComponent("keeploaded-webaudio\(suffix).json"))
                        }
                        self.note("keep loaded \(label): Web Audio \(phase), clock \(time.map(String.init(describing:)) ?? "missing"), engine \(page.engineReportsAudio == true)")
                        completion(time)
                    }
                }
            }
            // WebKit pages: also a Today tab playing through a detached Audio element (shown before "shown").
            let kinds = ["chat", "plain", "mail", "today"] + (webKit ? ["detached", "webaudio"] : []) + ["shown"]
            step { [self] done in
                guard port != 0 else { return done() }
                do {
                    let pid = c.store.profile(ofSpace: space).id
                    for k in kinds {
                        let host = ["plain", "shown", "detached", "webaudio"].contains(k) ? "127.0.0.1" : "localhost"
                        let t = try c.store.openTab(url: url(host, "/\(k)\(suffix)"), inSpace: space, activate: false, title: k)
                        ids[k] = t.id
                        if k == "chat" || k == "plain" { try c.store.togglePin(t.id, inSpace: space) }
                        if k == "mail" { try c.store.move(.tab(t.id), to: .favorites(profileID: pid, index: 0)) }
                    }
                } catch { check(false, "keep loaded \(label): setup (\(error))") }
                // Load every fixture before starting the short timeout. Zero disables Chromium's
                // timer but means immediately due to the app's WebKit timer, so use a long interval.
                WindowController.unloadOverride = 86_400
                c.applyUnloadSetting()
                c.reloadAll(animated: false)
                done()
            }
            for k in kinds {
                step { [self] done in
                    guard let id = ids[k] else { return done() }
                    c.show(id, focus: false)
                    waitUntil({ self.c.engineTab(for: id)?.title == k + suffix && self.c.engineTab(for: id)?.isLoading == false }, timeout: 8) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                    }
                }
                if k == "webaudio" {
                    step { [self] done in
                        guard let id = ids[k], let page = c.engineTab(for: id) as? WebKitTab else {
                            check(false, "keep loaded \(label): Web Audio fixture exists"); return done()
                        }
                        page.evaluate("__startAudio(); true") { _ in
                            recordAudio(page, "start") { start in
                                let deadline = Date().addingTimeInterval(8)
                                var baseline = start
                                func poll() {
                                    recordAudio(page, "before-hide") { now in
                                        if let first = baseline, let now { audioReady = now - first >= 0.25 }
                                        else { baseline = now }
                                        if audioReady || Date() >= deadline {
                                            self.check(audioReady, "keep loaded \(label): Web Audio clock advances before hiding and enabling unload")
                                            done()
                                        } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll) }
                                    }
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
                            }
                        }
                    }
                }
            }
            run { [self] in
                let pages = kinds.compactMap { ids[$0] }.compactMap { c.engineTab(for: $0) }
                let engines = pages.map { ProtectedMedia.isWebKitPage($0) || !chromium ? "WebKit" : "Chromium" }
                check(pages.count == kinds.count && Set(engines).count == 1 && (chromium ? (engines.first == "WebKit") == webKit : true),
                      "keep loaded \(label): all \(kinds.count) pages load (\(engines.joined(separator: ", ")))")
                check(c.store.tab(ids["chat"])?.isToday == false && c.store.item(c.store.tab(ids["mail"])?.itemID)?.isFavorite == true
                      && c.store.tab(ids["today"])?.isToday == true, "keep loaded \(label): a pinned tab, a Favorite, a Today tab")
                WindowController.unloadOverride = 2
                c.applyUnloadSetting()
            }
            let unloaded = { (k: String) in self.c.isPageUnloaded(ids[k]) }
            step { [self] done in
                // 2 s, the check's coalescing and the input check in the page.
                waitUntil({ unloaded("plain") && unloaded("today") }, timeout: 10) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: done)
                }
            }
            run { [self] in
                check(!unloaded("chat"), "keep loaded \(label): a pinned tab on a listed site stays loaded")
                check(!unloaded("mail"), "keep loaded \(label): a Favorite on a listed site stays loaded")
                check(unloaded("plain"), "keep loaded \(label): a pinned tab on an unlisted site unloads")
                check(unloaded("today"), "keep loaded \(label): a Today tab on a listed site unloads (only pinned tabs and Favorites stay)")
                check(!unloaded("shown"), "keep loaded \(label): the tab on screen stays")
            }
            if webKit {
                step { [self] done in
                    guard let id = ids["detached"], let t = c.engineTab(for: id) as? WebKitTab, !unloaded("detached") else {
                        check(false, "keep loaded \(label): a page playing through a detached Audio element stays loaded (unloaded)")
                        return done()
                    }
                    t.evaluate("[window.__played, !window.__detached.paused, document.contains(window.__detached)].join(' ')") { v in
                        let state = (v as? String) ?? "?"
                        self.check(state.hasPrefix("playing true false"),
                                   "keep loaded \(label): the detached Audio element plays, outside the document (\(state))")
                        self.check(t.engineReportsAudio == true && t.isAudible,
                                   "keep loaded \(label): WebKit and the media bridge both report detached audio (engine \(t.engineReportsAudio.map(String.init) ?? "n/a"), script \(t.isAudible))")
                        self.check(!unloaded("detached"), "keep loaded \(label): a hidden page playing through a detached Audio element stays loaded")
                        // Paused, it's an ordinary hidden page again.
                        t.evaluate("window.__detached.pause(); true") { _ in done() }
                    }
                }
                step { [self] done in
                    waitUntil({ unloaded("detached") }, timeout: 10) {
                        self.check(unloaded("detached"), "keep loaded \(label): once its sound pauses, it unloads")
                        done()
                    }
                }
            }
            if webKit {
                step { [self] done in
                    guard audioReady else { return done() } // A failed playback precondition is not an unload verdict.
                    guard let id = ids["webaudio"], let t = c.engineTab(for: id) as? WebKitTab else {
                        check(false, "keep loaded \(label): Web Audio page stays loaded"); return done()
                    }
                    check(t.engineReportsAudio == true && !t.isAudible,
                          "keep loaded \(label): Web Audio is protected by the engine alone (engine \(t.engineReportsAudio.map(String.init) ?? "n/a"), script \(t.isAudible))")
                    check(!unloaded("webaudio"), "keep loaded \(label): hidden engine-only audio stays loaded")
                    recordAudio(t, "retained-after-timeout") { _ in
                        t.evaluate("window.__audio.suspend(); true") { _ in done() }
                    }
                }
                step { [self] done in
                    guard audioReady else { return done() }
                    waitUntil({ unloaded("webaudio") }, timeout: 10) {
                        self.check(unloaded("webaudio"), "keep loaded \(label): once Web Audio stops, it unloads")
                        done()
                    }
                }
            }
            #if canImport(AircCore)
            if chromium && !webKit {
                run { [self] in
                    check(!c.appUnloadsChromiumPages, "keep loaded: Chromium owns its timeout")
                    // Disable the timeout: only the pressure signal may discard this fresh control.
                    WindowController.unloadOverride = 0
                    c.applyUnloadSetting()
                    if let id = ids["plain"] { c.show(id, focus: false) }
                }
                step { [self] done in
                    waitUntil({ ids["plain"].flatMap { self.c.engineTab(for: $0) }?.isLoading == false && !unloaded("plain") }, timeout: 8) { done() }
                }
                run { [self] in if let id = ids["shown"] { c.show(id, focus: false) } }
                wait(1)
                run { [self] in check(AircEngine.simulateMemoryPressure(forTesting: 2), "keep loaded: engine pressure hook accepted") }
                step { [self] done in
                    waitUntil({ unloaded("plain") }, timeout: 5) {
                        self.check(unloaded("plain"), "keep loaded: pressure unloads the unlisted control with timeout disabled")
                        self.check(!unloaded("chat") && !unloaded("mail"), "keep loaded: pressure preserves listed pin and Favorite")
                        done()
                    }
                }
            }
            #endif
            run { [self] in
                WindowController.unloadOverride = 2
                app?.settings.values.keepChatSitesLoaded = false
                c.applyUnloadSetting()
            }
            step { [self] done in
                waitUntil({ unloaded("chat") && unloaded("mail") }, timeout: 10) {
                    self.check(unloaded("chat") && unloaded("mail"),
                               "keep loaded \(label): with the setting off, they unload too (pinned \(unloaded("chat")), Favorite \(unloaded("mail")))")
                    done()
                }
            }
            run { [self] in
                app?.settings.values.keepChatSitesLoaded = true
                WindowController.unloadOverride = nil
                c.applyUnloadSetting()
                for k in kinds {
                    guard let id = ids[k] else { continue }
                    if let iid = c.store.tab(id)?.itemID { try? c.store.deleteItem(iid) } else { c.closeTab(id) }
                }
                c.reloadAll(animated: false)
            }
            wait(0.5)
        }

        round(chromium ? "(chromium, Chromium pages)" : "(webkit)", suffix: "", webKit: !chromium)
        #if canImport(AircCore)
        if chromium {
            run { ProtectedMedia.shared.testHosts = ["localhost", "127.0.0.1"] }
            round("(chromium, WebKit pages)", suffix: "2", webKit: true)
            run { ProtectedMedia.shared.testHosts = [] }
        }
        #endif
        run { [self] in
            WindowController.keepLoadedTestSites = []
            server?.stop()
        }
        wait(0.5)
    }

    private typealias Values = AppSettings.Values
}
#endif
