// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

/// Synthetic chat fixture; automated capture runs separately and pins an internal
/// browser tab, without camera, microphone or macOS screen recording.
enum P16bFixture {
    static let html = #"""
    <!doctype html><meta charset="utf-8"><title>Design review</title>
    <style>body{background:#203e46;color:#fff;font:17px system-ui;padding:50px}button{font:inherit;padding:12px;border:0;border-radius:10px}aside{background:#ffffff14;padding:24px;border-radius:16px;margin-top:24px}canvas{border-radius:20px;width:420px} [hidden]{display:none}</style>
    <h1>Design review</h1><p>Product team · Weekly planning</p>
    <canvas id="scene" width="640" height="360"></canvas><p>
    <button data-airc-call-chat data-unread-count="3" aria-label="Chat with everyone" aria-expanded="false">Chat · 3</button>
    <button id="share">Share a tab</button><button id="end">End call</button></p>
    <aside data-airc-chat-panel role="complementary" aria-label="In-call messages" hidden><h2>In-call messages</h2><p>Sam: The new layout looks good.</p><p>Alex: Let’s review the next tab.</p></aside>
    <video id="preview" autoplay muted playsinline width="320"></video><audio id="callAudio" autoplay loop src="data:audio/wav;base64,__SILENT_AUDIO__"></audio>
    <script>
    const button=document.querySelector('[data-airc-call-chat]'),panel=document.querySelector('aside');
    button.onclick=()=>{panel.hidden=!panel.hidden;button.setAttribute('aria-expanded',String(!panel.hidden));if(!panel.hidden){button.dataset.unreadCount='0';button.textContent='Chat'}};
    const context=scene.getContext('2d');let frame=0;
    setInterval(()=>{context.fillStyle='#315c67';context.fillRect(0,0,640,360);context.fillStyle='#d9edf0';context.font='32px system-ui';context.fillText('Design review',30,80);context.font='21px system-ui';context.fillText('Navigation · layout · next steps',30,140);context.fillStyle='#b8e6ce';context.beginPath();context.arc(48+(++frame%80),260,12,0,Math.PI*2);context.fill()},100);
    window.synthetic=scene.captureStream(10);preview.srcObject=synthetic;
    navigator.mediaSession.metadata=new MediaMetadata({title:'Design review'});
    callAudio.play().then(()=>navigator.mediaSession.playbackState='playing').catch(e=>window.playError=e.name);
    share.onclick=async()=>{try{window.shared=await navigator.mediaDevices.getDisplayMedia({video:true,audio:false,preferCurrentTab:true,surfaceSwitching:'include'});preview.srcObject=shared;window.captureState='capturing';shared.getVideoTracks()[0].onended=()=>window.captureState='stopped'}catch(e){window.captureState=e.name}};
    navigator.mediaSession?.setActionHandler('hangup',()=>end.click());
    end.onclick=()=>{navigator.mediaSession?.setActionHandler('hangup',null);preview.pause();preview.srcObject=null;callAudio.pause();callAudio.removeAttribute('src');callAudio.load();navigator.mediaSession.playbackState='none';synthetic.getTracks().forEach(t=>t.stop());window.shared?.getTracks().forEach(t=>t.stop());button.hidden=true;panel.hidden=true;window.ended=true};
    </script>
    """#.replacingOccurrences(of: "__SILENT_AUDIO__", with: silentAudio.base64EncodedString())

    // File-backed silent playback gives Chromium a media-session route; a bare
    // MediaStream preview has no audio focus and cannot route the site's actions.
    private static let silentAudio: Data = {
        let samples = 16_000 * 8
        var data = Data()
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        data.append(Data(count: samples * 2)); return data
    }()
}

extension SnapshotRunner {
    func parityP16bScenario() {
        run { [self] in callControlOwnershipChecks() }
        var server: LocalPageServer?
        var call = "", target = ""
        let tools = CallTools.shared
        func page() -> EngineTab? { c.engineTab(for: call) }
        step { [self] done in
            server = LocalPageServer(pages: ["/call": P16bFixture.html, "/target": "<title>Next design</title><body style='background:#8d3c52'>Synthetic target</body>"])
            server?.start { port in
                guard let port else { self.check(false, "p16b fixture server"); return done() }
                let base = "http://127.0.0.1:\(port)"
                call = (try? self.c.store.openTab(url: base + "/call", inSpace: self.c.currentSpaceID, title: "Design review"))?.id ?? ""
                target = (try? self.c.store.openTab(url: base + "/target", inSpace: self.c.currentSpaceID, title: "Next design"))?.id ?? ""
                self.c.reloadAll(animated: false); self.c.show(call, focus: false); done()
            }
        }
        wait(2)
        step { [self] done in
            waitUntil({ MediaLibrary.shared.media?.sessions[call]?.isCall == true }, timeout: 8) {
                self.check(MediaLibrary.shared.media?.sessions[call]?.isCall == true, "p16b synthetic call reaches production media observer")
                done()
            }
        }
        step { [self] done in
            guard let p = page() else { self.check(false, "p16b page loaded"); return done() }
            CallChat.read(p, fixture: true) { state in
                self.check(state.available && !state.open && state.unread == 3, "p16b DOM unread badge is 3")
                done()
            }
        }
        step { [self] done in
            guard let p = page(), let script = CallChat.script(url: URL(string: "https://meet.google.com/fixture")) else { return done() }
            p.evaluate(script) { result in
                let state = result as? [String: Any]
                self.check(state?["available"] as? Bool == true && state?["unread"] as? Int == 3, "p16b Meet selector seam reads synthetic provider DOM")
                done()
            }
        }
        step { [self] done in
            guard let p = page() else { return done() }
            CallChat.read(p, toggle: true, fixture: true) { state in
                self.check(state.open && state.unread == 0, "p16b native chat action clicks site button; badge clears")
                done()
            }
        }
        step { [self] done in
            guard let p = page() else { return done() }
            CallChat.read(p, toggle: true, fixture: true) { state in
                self.check(!state.open, "p16b second toggle closes site panel"); done()
            }
        }
        run { [self] in
            tools.update(call, page: page(), active: true)
            self.check(!tools.canSwitch(call, to: self.c.engineTab(for: target)), "p16b no capture cannot switch")
            self.check(!tools.switchTo(nil, call: call), "p16b nil target rejected")
            self.check(CallChat.script(url: URL(string: "https://example.org")) == nil, "p16b unsupported provider has no DOM action")
            self.check(CallChat.script(url: URL(string: "https://meet.google.com.evil.invalid")) == nil, "p16b lookalike host refused")
        }
        wait(0.5)
        run { [self] in
            self.check(tools.chat[call]?.available == true, "p16b call UI observes chat state")
            let calls = MediaLibrary.shared.calls
            calls.open(call, .left)
            let view = calls.window?.contentView as? CallWindowView
            view?.layoutSubtreeIfNeeded()
            self.check(view != nil && view?.showsCallTools == false,
                       "callcontrols: available chat does not add a second row above full page")
            calls.returnPage(showing: false)
            let tile = PiPControlsView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
            tile.callTabID = call
            var state = PiPControlsState(); state.call = true
            tile.update(state)
            tile.layoutSubtreeIfNeeded()
            self.check(!tile.chat.isHidden, "callcontrols: tile exposes the available provider chat action")
            tile.chat.action?()
        }
        step { [self] done in
            waitUntil({ tools.chat[call]?.open == true }, timeout: 4) {
                self.check(tools.chat[call]?.open == true, "callcontrols: native tile Chat opens the provider panel")
                done()
            }
        }
        step { done in page()?.evaluate("end.click(); true") { _ in done() } }
        step { [self] done in
            waitUntil({ tools.chat[call] == nil && tools.sharedTabs[call] == nil }, timeout: 8) {
                self.check(tools.chat[call] == nil && tools.sharedTabs[call] == nil, "p16b ended fixture call clears production UI state")
                done()
            }
        }
        run {
            tools.update(call, page: nil, active: false)
            server?.stop()
        }
    }
}
#endif

#if AIRC_TESTING && canImport(AircCore)
import AircCore
extension SnapshotRunner {
    /// Tab-only synthetic capture. Run with the exact auto-select tab title;
    /// preferCurrentTab chooses Chromium's tab-only picker (no OS window list),
    /// monitor surfaces and audio are excluded. No real call/account/device.
    func parityP16bCaptureScenario() {
        guard let engine = app?.engine as? ChromiumEngine else { return }
        guard CommandLine.arguments.contains("--auto-select-tab-capture-source-by-title=P16b source red") else {
            run { [self] in check(false, "p16b capture refused without pinned synthetic tab selector") }; return
        }
        var server: LocalPageServer?, base = ""
        var call = "", red = "", blue = ""
        var foreign: EngineTab?, privateTab: EngineTab?
        var privateProfile: EngineProfile?
        var events: [[String: Any]] = []
        func page(_ id: String) -> EngineTab? { c.engineTab(for: id) }
        func js(_ expression: String, _ done: @escaping (Any?) -> Void) {
            guard let p = page(call) else { done(nil); return }
            p.evaluate(expression, completion: done)
        }
        func expectJS(_ expression: String, _ label: String) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(12)
                func poll() {
                    js(expression) { value in
                        if value as? Bool == true { self.check(true, label); done() }
                        else if Date() > deadline { self.check(false, label + " (\(value ?? "nil"))"); done() }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll) }
                    }
                }
                poll()
            }
        }
        step { [self] done in
            self.check(CommandLine.arguments.contains("--auto-select-tab-capture-source-by-title=P16b source red"), "p16b capture is pinned to synthetic tab title")
            server = LocalPageServer(pages: ["/call": P16bFixture.html + "<style>html,body{background:rgb(220,20,20)}</style><script>document.title='P16b source red'</script>",
                "/blue": "<title>P16b source blue</title><style>html,body{margin:0;background:rgb(20,20,220);width:100%;height:100%}</style>"])
            server?.start { port in
                guard let port else { self.check(false, "p16b capture server"); return done() }
                base = "http://127.0.0.1:\(port)"
                call = (try? self.c.store.openTab(url: base + "/call", inSpace: self.c.currentSpaceID))?.id ?? ""
                red = call
                blue = (try? self.c.store.openTab(url: base + "/blue", inSpace: self.c.currentSpaceID))?.id ?? ""
                self.c.reloadAll(animated: false); self.c.show(red, focus: false); done()
            }
        }
        wait(1.5)
        run { [self] in c.show(blue, focus: false) }
        wait(1.5)
        run { [self] in c.show(call, focus: false) }
        wait(1.5)
        step { [self] done in
            guard let p = page(call) as? ChromiumTab, let profile = p.profile as? ChromiumProfile else { return done() }
            CallTools.shared.update(call, page: p, active: true)
            profile.core.observeCallShares { [weak profile] rows in
                events.append(contentsOf: rows)
                if let profile { CallTools.shared.captureChanged(profile, rows: rows) }
            }
            engine.devToolsCall("Runtime.evaluate", params: ["expression": """
              window.captureState='starting';
              navigator.mediaDevices.getDisplayMedia({video:true,audio:false,preferCurrentTab:true,monitorTypeSurfaces:'exclude',surfaceSwitching:'include'})
                .then(s=>{window.shared=s;preview.srcObject=s;window.captureState='capturing';s.getVideoTracks()[0].onended=()=>window.captureState='stopped'})
                .catch(e=>window.captureState=e.name);
              window.pixel=()=>{if(!preview.videoWidth)return [];const c=document.createElement('canvas');c.width=c.height=1;c.getContext('2d').drawImage(preview,4,4,1,1,0,0,1,1);return Array.from(c.getContext('2d').getImageData(0,0,1,1).data)};
              """, "userGesture": true, "returnByValue": true], in: p) { _, _ in done() }
        }
        expectJS("window.captureState==='capturing' && shared.getVideoTracks()[0].getSettings().displaySurface==='browser'", "p16b capture is an internal browser-tab surface")
        expectJS("pixel()[0]>150 && pixel()[2]<80", "p16b received frames originate from red source")
        step { [self] done in
            engine.loadProfile(directory: "P16b-other") { profile in
                if let profile { foreign = self.c.engineWindow.openTab(url: URL(string: base + "/blue"), profile: profile, foreground: false) }
                guard let p = page(call) else { return done() }
                engine.offTheRecordProfile(for: p.profile) { profile in
                    privateProfile = profile
                    if let profile { privateTab = self.c.engineWindow.openTab(url: URL(string: base + "/blue"), profile: profile, foreground: false) }
                    done()
                }
            }
        }
        run { [self] in
            guard let p = page(call) as? ChromiumTab, let target = page(blue) as? ChromiumTab,
                  let foreign = foreign as? ChromiumTab, let privateTab = privateTab as? ChromiumTab else {
                check(false, "p16b all profile targets created"); return
            }
            check(!foreign.core.canShareThisTabInstead(for: p.core) && !foreign.core.shareThisTabInstead(for: p.core), "p16b cross-profile target rejected during live capture")
            check(!privateTab.core.canShareThisTabInstead(for: p.core) && !privateTab.core.shareThisTabInstead(for: p.core), "p16b private target rejected during normal-profile capture")
            check(target.core.canShareThisTabInstead(for: p.core), "p16b same-profile source can switch")
            c.show(blue, focus: false)
            check(CallTools.shared.canSwitch(call, to: c.promptShownPage), "p16b current tab offers replacement in call controls")
            check(CallTools.shared.switchTo(c.promptShownPage, call: call), "p16b call control switch accepted by Chromium")
            check(!target.core.shareThisTabInstead(for: p.core), "p16b duplicate switch rejected")
        }
        expectJS("pixel()[2]>150 && pixel()[0]<80", "p16b received frames switch to blue source")
        step { [self] done in waitUntil({ events.contains { ($0["state"] as? String) == "switched" } }, timeout: 3, then: done) }
        run { [self] in
            guard let p = page(call) as? ChromiumTab, let profile = p.profile as? ChromiumProfile else { return }
            check(profile.core.callShares().contains { ($0["sharedTabID"] as? Int) == page(blue)?.tabID }, "p16b engine confirms new shared tab")
            check(events.contains { ($0["state"] as? String) == "switched" }, "p16b switched callback delivered after replacement")
            check(CallTools.shared.isShared(page(blue)) && !CallTools.shared.isShared(page(red)), "p16b shared-row indicator follows confirmed source")
            check(!CallTools.shared.canSwitch(call, to: page(blue)), "p16b current shared source hides replacement action")
            CallTools.shared.stop(call)
        }
        expectJS("window.captureState==='stopped'", "p16b original captured track ends on Stop Sharing")
        step { [self] done in waitUntil({ events.contains { ($0["state"] as? String) == "stopped" } }, timeout: 3, then: done) }
        run { [self] in
            if let p = page(call)?.profile as? ChromiumProfile {
                check(p.core.callShares().isEmpty, "p16b stopped snapshot clears source")
                check(!CallTools.shared.isShared(page(blue)), "p16b Stop Sharing clears the row indicator")
                check(events.contains { ($0["state"] as? String) == "stopped" }, "p16b stopped callback delivered")
                p.core.observeCallShares(nil)
            }
            note("p16b callback states: " + events.compactMap { $0["state"] as? String }.joined(separator: ", "))
            CallTools.shared.update(call, page: nil, active: false)
            foreign?.close(); privateTab?.close()
            // Profile wrappers are engine-owned; closing the private tab removes its capture target.
            _ = privateProfile
            server?.stop()
        }
    }
}
#endif
