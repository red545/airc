// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    func videoAdsScenario() {
        step { [self] done in Task { @MainActor in
            await VideoAdsCheck(runner: self).run(); done()
        } }
    }
}

@MainActor private final class VideoAdsCheck {
    let runner: SnapshotRunner
    var c: WindowController { runner.c }
    var app: AppDelegate { runner.app! }
    var center: BlockingCenter { app.blocking }
    var id: String { c.store.profile(ofSpace: c.currentSpaceID).id }
    var server: LocalPageServer?
    var base: URL!
    var privateWindow: PrivateWindowController?
    init(runner: SnapshotRunner) { self.runner = runner }
    func check(_ ok: Bool, _ name: String) { runner.check(ok, "ytads: " + name) }
    func js(_ tab: EngineTab, _ source: String) async -> Any? {
        await withCheckedContinuation { resume in tab.evaluate(source) { resume.resume(returning: $0) } }
    }
    func wait(_ predicate: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
    func load(_ tab: EngineTab, enabled: Bool, label: String) async {
        let token = UUID().uuidString
        tab.load(URL(string: base.absoluteString + "?token=" + token + (enabled ? "" : "&off=1"))!)
        let ready = await wait {
            await self.js(tab, "location.search.includes('\(token)') && document.documentElement.dataset.fixtureDone === 'yes'") as? Bool == true
        }
        check(ready, label + " fixture completed")
        let results = await js(tab, "window.fixtureResults") as? [[String: Any]] ?? []
        check(results.count >= 15, label + " results present")
        for result in results { check(result["pass"] as? Bool == true, label + " " + (result["name"] as? String ?? "unnamed")) }
        let hidden = await wait { await self.js(tab, "getComputedStyle(document.querySelector('ytd-ad-slot-renderer')).display === 'none'") as? Bool == enabled }
        check(hidden, label + " cosmetic policy")
    }
    func site(_ enabled: Bool, _ tab: EngineTab) async {
        await withCheckedContinuation { resume in center.setSiteEnabled(enabled, tab: tab) { resume.resume() } }
    }
    func install(_ profile: String) async {
        let rules = """
        localhost##+js(airc-video-prune)
        localhost##ytd-ad-slot-renderer
        /doubleclick/ad$xmlhttprequest
        /youtube/api/stats/ads$xmlhttprequest
        """
        await withCheckedContinuation { resume in center.installCheckRules(rules, profile: profile) { resume.resume() } }
    }
    func run() async {
        defer { privateWindow?.closeWindow(); server?.stop() }
        guard let root = ProcessInfo.processInfo.environment["AIRC_YTADS_SOURCE"] else { check(false, "fixture source directory supplied"); return }
        let directory = URL(fileURLWithPath: root)
        guard let html = try? String(contentsOf: directory.appendingPathComponent("infra/ytads/fixture.html")),
              let media = try? Data(contentsOf: directory.appendingPathComponent("apps/marketing/public/video/command.mp4")) else {
            check(false, "local HTML and video loaded"); return
        }
        server = LocalPageServer(pages: [:])
        // Chromium treats an HTTP movie without range support as unseekable.
        // Keep this real HTTP media path; do not substitute a blob or fake seek.
        server?.requestHandler = { request in
            guard request.path == "/movie.mp4" else { return nil }
            var headers = ["Content-Type":"video/mp4", "Accept-Ranges":"bytes"]
            guard let range = request.headers["range"] else { return .init(headers: headers, body: "", data: media) }
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            var start = 0, end = media.count - 1
            if range.hasPrefix("bytes="), bounds.count == 2 {
                if bounds[0].isEmpty, let suffix = Int(bounds[1]), suffix > 0 { start = max(0, media.count - suffix) }
                else if let first = Int(bounds[0]) { start = first }
                else { start = -1 }
                if !bounds[0].isEmpty && !bounds[1].isEmpty { end = min(Int(bounds[1]) ?? -1, end) }
            } else { start = -1 }
            guard start >= 0, start <= end, start < media.count else {
                return .init(status: "416 Range Not Satisfiable", headers: ["Content-Range":"bytes */\(media.count)"], body: "")
            }
            headers["Content-Range"] = "bytes \(start)-\(end)/\(media.count)"
            return .init(status: "206 Partial Content", headers: headers, body: "", data: media.subdata(in: start..<(end + 1)))
        }
        let payload = #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"fixture"},"streamingData":{"formats":[{"url":"/movie.mp4"}]},"captions":{"fixture":"preserved"},"adPlacements":[{"kind":"preroll"},{"kind":"midroll"}],"playerAds":[1],"adSlots":[1]}"#
        server?.handler = { path in
            switch path {
            case "/youtubei/v1/player": return .init(headers: ["Content-Type":"application/json"], body: payload)
            case "/movie.mp4": return .init(headers: ["Content-Type":"video/mp4"], body: "", data: media)
            case "/captions.vtt": return .init(headers: ["Content-Type":"text/vtt"], body: "WEBVTT\n\n00:00.000 --> 00:20.000\nFixture captions\n")
            case "/doubleclick/ad", "/youtube/api/stats/ads": return .init(body: "ad")
            default: return .init(body: html)
            }
        }
        guard let server else { check(false,"server created"); return }
        let port: UInt16 = await withCheckedContinuation { resume in server.start { resume.resume(returning: $0 ?? 0) } }
        guard port > 0 else { check(false, "loopback server starts"); return }
        base = URL(string: "http://localhost:\(port)/")!
        await install(id)
        guard let row = try? c.store.openTab(url: base.absoluteString, inSpace: c.currentSpaceID) else { check(false,"create tab"); return }
        c.reloadAll(animated: false); c.show(row.id, focus: false)
        guard let tab = c.engineTab(for: row.id) else { check(false,"engine tab exists"); return }
        await load(tab, enabled: true, label: "on")
        await withCheckedContinuation { resume in runner.captureNow("ytads-fixture-on") { resume.resume() } }
        // Local playable media: seek and actual caption cues, not just JSON shape.
        _ = await js(tab, "window.v=document.querySelector('video');v.muted=true;v.play().catch(()=>{});true")
        let playing = await wait { await self.js(tab,"v.currentTime > 0.2 && !v.paused") as? Bool == true }
        check(playing,"local video plays")
        _ = await js(tab,"v.pause();v.currentTime=2;v.textTracks[0].mode='showing';true")
        let mediaOK = await wait { await self.js(tab,"Math.abs(v.currentTime-2)<0.3 && v.textTracks[0].cues.length>0") as? Bool == true }
        check(mediaOK,"seek and captions work")
        // The native mini-player selects playing videos. Resume after the
        // deliberately paused seek, and loop this four-second local movie.
        _ = await js(tab,"v.loop=true;v.play().catch(()=>{});true")
        let resumed = await wait { await self.js(tab,"!v.paused && !v.ended && v.readyState>2") as? Bool == true }
        check(resumed,"video resumes before PiP")
        let pip: Bool = await withCheckedContinuation { resume in app.engine.enterPictureInPictureForHost(tab) { _, opened in resume.resume(returning: opened) } }
        let pipVisible = await wait { await self.js(tab,"document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture'") as? Bool == true }
        check(pip || pipVisible,"native PiP request opens")
        _ = await js(tab,"if(document.pictureInPictureElement)document.exitPictureInPicture();else if(v.webkitPresentationMode==='picture-in-picture')v.webkitSetPresentationMode('inline');true")
        await site(false, tab); await load(tab, enabled: false, label: "site exception")
        await site(true, tab); await load(tab, enabled: true, label: "site restored")
        await withCheckedContinuation { resume in center.setCheckEnabled(false, profile: id) { resume.resume() } }
        await load(tab, enabled: false, label: "profile off")
        await withCheckedContinuation { resume in center.setCheckEnabled(true, profile: id) { resume.resume() } }
        await load(tab, enabled: true, label: "profile on")
        if let other = try? c.profiles.createProfile(name: "Video off", emoji: "🧪", color: nil) {
            let profile: EngineProfile? = await withCheckedContinuation { resume in c.profiles.whenLoaded(other.id, { resume.resume(returning:$0) }, failed: { resume.resume(returning:nil) }) }
            if let profile {
                await install(other.id)
                await withCheckedContinuation { resume in center.setCheckEnabled(false, profile: other.id) { resume.resume() } }
                let window = app.engine.makeWindow(contentRect:NSRect(x:0,y:0,width:800,height:600))
                let otherTab = window.openTab(url:nil,profile:profile,foreground:true)
                await load(otherTab,enabled:false,label:"second profile off")
                await load(tab,enabled:true,label:"first profile unchanged")
                otherTab.close();window.window.close()
            } else { check(false,"second profile loaded") }
        } else { check(false,"second profile created") }
        let before = center.settings.configuration(id)
        privateWindow = await withCheckedContinuation { resume in PrivateBrowsing.shared.open(app:app) { resume.resume(returning:$0) } }
        if let window = privateWindow {
            let privateTab = window.openPage(base)
            await load(privateTab,enabled:true,label:"private inherits on")
            await site(false,privateTab);await load(privateTab,enabled:false,label:"private exception")
            check(before == center.settings.configuration(id),"private exception does not persist into regular profile")
            await load(tab,enabled:true,label:"regular unaffected")
        } else { check(false,"private window created") }
        check(center.failures.isEmpty,"blocking configuration healthy")
    }
}
#endif
