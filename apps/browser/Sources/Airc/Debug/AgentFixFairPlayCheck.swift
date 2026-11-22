// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// agentfix, `--script agentfixfairplay` (Chromium; the FairPlay bridge is Chromium's), review21's false "couldn't play
/// here": a loopback page of a listed video site asks for Widevine (refused) and then FairPlay (offered), and never
/// plays, as Netflix's and Disney+'s players probe at load. No offer may come after the stalled-offer delay. A control
/// page that asks for Widevine only and stops there still gets the offer. No real streaming site, no account, no
/// protected content.
extension SnapshotRunner {
    #if canImport(AircCore)
    func agentFixFairPlayScenario() {
        guard app?.engine is ChromiumEngine else { return run { self.note("agentfixfairplay: Chromium only (the FairPlay bridge is Chromium's)") } }
        let tag = "agentfixfairplay"
        var server: LocalPageServer?
        var port: UInt16 = 0
        var offers: [(tab: EngineTab?, step: String)] = []
        var observer: NSObjectProtocol?
        var both = "", control = ""
        let cfg = #"[{initDataTypes:['skd','sinf','cenc'],videoCapabilities:[{contentType:'video/mp4; codecs="avc1.640015"',robustness:''}]}]"#
        // The probe at load, then nothing: no MediaSource, no playback.
        let probeBoth = "<!doctype html><title>Browse</title><p>A catalogue page.</p><script>var st=window.__st={};var cfg=\(cfg);"
            + "navigator.requestMediaKeySystemAccess('com.widevine.alpha',cfg).then(function(){st.wv='granted'},function(e){st.wv=e.name})"
            + ".then(function(){return navigator.requestMediaKeySystemAccess('com.apple.fps',cfg)}).then(function(){st.fps='granted'},function(e){st.fps=e.name})"
            + ".then(function(){st.done=true})</script>"
        let probeWidevine = "<!doctype html><title>Stuck</title><p>A player that stops at Widevine.</p><script>var st=window.__st={};var cfg=\(cfg);"
            + "navigator.requestMediaKeySystemAccess('com.widevine.alpha',cfg).then(function(){st.wv='granted'},function(e){st.wv=e.name}).then(function(){st.done=true})</script>"
        func open(_ u: String) -> String {
            guard let t = try? c.store.openTab(url: u, inSpace: c.currentSpaceID) else { return "" }
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            return t.id
        }
        func state(_ id: String, _ done: @escaping ([String: Any]) -> Void) {
            guard let p = c.engineTab(for: id) else { return done([:]) }
            p.evaluate("JSON.stringify(window.__st || {})") { v in
                done((v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:])
            }
        }
        step { done in
            server = LocalPageServer(responses: ["/both": .init(body: probeBoth), "/stuck": .init(body: probeWidevine)])
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            check(port != 0, "\(tag): loopback server")
            ProtectedMedia.shared.testHosts = ["localhost"]
            FairPlayBridge.testVideoOrigin = "http://localhost:\(port)"
            FairPlayBridge.forcedForTest = true
            observer = NotificationCenter.default.addObserver(forName: FairPlayBridge.failed, object: nil, queue: .main) { n in
                offers.append((n.object as? EngineTab, n.userInfo?["step"] as? String ?? ""))
            }
        }
        wait(0.6)
        run { both = open("http://localhost:\(port)/both"); control = open("http://localhost:\(port)/stuck") }
        step { [self] done in
            waitUntil({ self.c.engineTab(for: both)?.isLoading == false && self.c.engineTab(for: control)?.isLoading == false }, timeout: 10, then: done)
        }
        wait(1.0)
        step { [self] done in
            state(both) { s in
                self.check(s["wv"] as? String == "NotSupportedError" && s["fps"] as? String == "granted",
                           "\(tag): the browse page asked Widevine (refused: \(s["wv"] ?? "-")), then FairPlay (offered: \(s["fps"] ?? "-"))")
                state(control) { s in
                    self.check(s["wv"] as? String == "NotSupportedError" && s["done"] as? Bool == true, "\(tag): the control page asked Widevine only (\(s["wv"] ?? "-"))")
                    done()
                }
            }
        }
        // Past the stalled-offer delay (10 s from the Widevine refusal), browsing on.
        wait(FairPlayBridge.stalledOfferDelay + 2.5)
        run { [self] in
            let bothTab = c.engineTab(for: both), controlTab = c.engineTab(for: control)
            let onBoth = offers.filter { $0.tab != nil && $0.tab === bothTab }
            let onControl = offers.filter { $0.tab != nil && $0.tab === controlTab && $0.step == "keysystem" }
            note("\(tag): offers after \(FairPlayBridge.stalledOfferDelay + 2.5) s: \(offers.map { ($0.tab === bothTab ? "browse" : $0.tab === controlTab ? "control" : "other") + ":" + $0.step })")
            check(onBoth.isEmpty, "\(tag): a page offered FairPlay that never plays gets no “couldn't play here” offer (\(onBoth.map(\.step)))")
            check(onControl.count == 1, "\(tag): the control page that stops at Widevine still gets Safari's-engine offer (\(onControl.count))")
            for id in [both, control] { c.engineTab(for: id)?.close() }
            if let o = observer { NotificationCenter.default.removeObserver(o) }
            FairPlayBridge.testVideoOrigin = nil
            FairPlayBridge.forcedForTest = nil
            ProtectedMedia.shared.testHosts = []
            server?.stop()
        }
    }
    #endif
}
#endif
