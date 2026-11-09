// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

extension SnapshotRunner {
    /// Discard retries, lifecycle cancellation and the Web Audio fixture's preconditions.
    /// Uses only page evaluation and app APIs; no HID, clipboard or capture.
    func scrollRestoreAuxScenario() {
        var server: LocalPageServer?, port: UInt16 = 0
        var rows: [[String: Any]] = []
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: self.dir.appendingPathComponent("scrollrestore-aux.json"))
            }
        }
        step { [self] done in
            server = LocalPageServer(pages: [
                "/page": "<!doctype html><title>cancel fixture</title><main style='height:6000px'>fixture<input id='draft' value=''></main><script>window.scrollFixtureInstance=String(Date.now())+'-'+Math.random()</script>",
                "/other": "<!doctype html><title>other</title>other",
                "/next": "<!doctype html><title>next</title>next",
                "/audio": """
                <!doctype html><title>audio fixture</title><script>
                window.__audio=new AudioContext();
                const tone=__audio.createOscillator(),gain=__audio.createGain();
                gain.gain.value=0.00001;tone.connect(gain).connect(__audio.destination);
                tone.start();__audio.resume();
                </script>
                """
            ])
            server?.start { p in port = p ?? 0; self.check(port != 0, "aux: server starts"); done() }
        }
        #if canImport(AircCore)
        if app?.engine is ChromiumEngine {
            for action in ["select", "navigate", "close", "timeout", "retry-select", "retry-select-hide", "retry-navigate", "retry-close", "retry-dirty", "retry-pin"] {
                var id: String?, other: String?, instance: String?
                var row: [String: Any] = ["action": action]
                run { [self] in
                    WindowController.unloadOverride = 86400; c.applyUnloadSetting()
                    id = (try? c.store.openTab(url: "http://127.0.0.1:\(port)/page", inSpace: c.currentSpaceID, activate: false))?.id
                    other = (try? c.store.openTab(url: "http://127.0.0.1:\(port)/other", inSpace: c.currentSpaceID, activate: false))?.id
                    c.reloadAll(animated: false); if let id { c.show(id, focus: false) }
                }
                step { [self] done in
                    waitUntil({ id.flatMap { self.c.engineTab(for: $0) }?.title == "cancel fixture" && id.flatMap { self.c.engineTab(for: $0) }?.isLoading == false }, timeout: 10) { done() }
                }
                step { [self] done in
                    guard let page = id.flatMap({ c.engineTab(for: $0) }) else { return done() }
                    page.evaluate("scrollTo(0,700);window.scrollFixtureInstance") { value in
                        instance = value as? String
                        if let other { self.c.show(other, focus: false) }; done()
                    }
                }
                wait(0.5)
                run { [self] in
                    guard let id, let page = c.engineTab(for: id) else { return }
                    if action == "timeout" || action.hasPrefix("retry-") {
                        let edit = action == "retry-dirty" ? "document.getElementById('draft').value='keep me';" : ""
                        page.evaluate("(()=>{const end=Date.now()+3500;while(Date.now()<end){};\(edit)return true})()", completion: nil)
                    }
                    let accepted = page.discard(); row["accepted"] = accepted
                    check(accepted, "aux \(action): discard request accepted")
                    if action.hasPrefix("retry-") {
                        // The two-second ACK deadline has passed; cancel or add a
                        // protection while the retry is waiting for its backoff.
                        DispatchQueue.main.asyncAfter(deadline: .now() + (action == "retry-select-hide" ? 3.1 : 2.5)) {
                            switch action {
                            case "retry-select": self.c.show(id, focus: false)
                            case "retry-select-hide":
                                self.c.show(id, focus: false)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    if let other { self.c.show(other, focus: false) }
                                }
                            case "retry-navigate": page.load(URL(string: "http://127.0.0.1:\(port)/next")!)
                            case "retry-close": self.c.discardScratchTab(id)
                            case "retry-pin": (page as? ChromiumTab)?.core.setAutoDiscardable(false)
                            default: break
                            }
                        }
                    }
                    switch action {
                    case "select": c.show(id, focus: false)
                    case "navigate": page.load(URL(string: "http://127.0.0.1:\(port)/next")!)
                    case "close": c.discardScratchTab(id)
                    default: break
                    }
                }
                wait(5)
                step { [self] done in
                    if action == "close" || action == "retry-close" {
                        let closed = id.flatMap { c.engineTab(for: $0) } == nil
                        row["cancelled"] = closed; check(closed, "aux close: no stale page mapping")
                        rows.append(row); save(); return done()
                    }
                    guard let id, let page = c.engineTab(for: id) else {
                        check(false, "aux \(action): page remains mapped"); return done()
                    }
                    if action == "timeout" {
                        let retried = self.c.isPageUnloaded(id)
                        row["retry_unloaded"] = retried
                        self.check(retried, "aux timeout: delayed renderer recovers and the accepted discard retries")
                        rows.append(row); save(); return done()
                    }
                    scrollRestoreSample(page) { sample in
                        let kept = !self.c.isPageUnloaded(id) && (action == "navigate" || action == "retry-navigate"
                            ? page.title == "next" : sample["instance"] as? String == instance && (sample["y"] as? Double) == 700)
                        row["sample"] = sample; row["cancelled"] = kept
                        self.check(kept, "aux \(action): pending discard cancelled without losing the page")
                        rows.append(row); save(); done()
                    }
                }
                run { [self] in for tab in [id, other].compactMap({ $0 }) { c.discardScratchTab(tab) } }
            }
        }
        #endif
        if ProcessInfo.processInfo.environment["AIRC_SCROLL_AUX_NATIVE_ONLY"] == "1" {
            run { [self] in WindowController.unloadOverride = nil; c.applyUnloadSetting(); server?.stop() }
            return
        }
        var audioID: String?, otherID: String?
        var audioRow: [String: Any] = ["action": "webaudio-precondition"]
        run { [self] in
            #if canImport(AircCore)
            ProtectedMedia.shared.testHosts = ["127.0.0.1"]
            #endif
            WindowController.unloadOverride = 86400; c.applyUnloadSetting()
            app?.settings.values.pipAutomatic = false; c.applyPictureInPictureSettings()
            audioID = (try? c.store.openTab(url: "http://127.0.0.1:\(port)/audio", inSpace: c.currentSpaceID, activate: false))?.id
            otherID = (try? c.store.openTab(url: "http://127.0.0.1:\(port)/other", inSpace: c.currentSpaceID, activate: false))?.id
            c.reloadAll(animated: false); if let audioID { c.show(audioID, focus: false) }
        }
        step { [self] done in
            waitUntil({ audioID.flatMap { self.c.engineTab(for: $0) }?.title == "audio fixture" }, timeout: 10) { done() }
        }
        for name in ["before", "after_one_second"] {
            wait(1)
            step { [self] done in
                guard let page = audioID.flatMap({ c.engineTab(for: $0) }) as? WebKitTab else {
                    check(false, "aux: WebKit audio fixture exists"); return done()
                }
                page.evaluate("({state:__audio.state,time:__audio.currentTime,visibility:document.visibilityState})") { value in
                    var sample = value as? [String: Any] ?? [:]
                    sample["engine_audio"] = page.engineReportsAudio ?? false
                    sample["script_audible"] = page.isAudible; sample["plays_media"] = page.playsMedia
                    sample["screen_locked"] = Self.screenLocked
                    audioRow[name] = sample; done()
                }
            }
        }
        run { [self] in
            if let otherID { c.show(otherID, focus: false) }
            WindowController.unloadOverride = 2; c.applyUnloadSetting()
        }
        wait(5)
        run { [self] in
            audioRow["unloaded"] = audioID.map { c.isPageUnloaded($0) } ?? true
            rows.append(audioRow); save()
            for id in [audioID, otherID].compactMap({ $0 }) { c.discardScratchTab(id) }
            #if canImport(AircCore)
            ProtectedMedia.shared.testHosts = []
            #endif
            WindowController.unloadOverride = nil; c.applyUnloadSetting(); server?.stop()
        }
    }
}
#endif
