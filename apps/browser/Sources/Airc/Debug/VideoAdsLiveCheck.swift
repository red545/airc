// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit

extension SnapshotRunner {
    /// One short, signed-out public-page observation per UI-lock hold. Never CI.
    func videoAdsLiveScenario() {
        step { [self] done in Task { @MainActor in
            guard let app else { return done() }
            let target = ProcessInfo.processInfo.environment["AIRC_YTADS_VIDEO"] ?? "home"
            // The operator freezes the regional candidate manifest before the run.
            let isVideo = target.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
            let address: String
            if target == "home" { address = "https://www.youtube.com/" }
            else if target == "search" { address = "https://www.youtube.com/results?search_query=official+music+video+2026" }
            else if isVideo { address = "https://www.youtube.com/watch?v=" + target }
            else { check(false,"ytads-live: explicit 11-character public video ID required"); return done() }
            @MainActor func evaluate(_ tab: EngineTab, _ source: String) async -> Any? {
                await withCheckedContinuation { resume in tab.evaluate(source) { resume.resume(returning:$0) } }
            }
            PageScripts.shared?.set("ytadsobserve", source: Self.videoAdsObservationScript, frames: false) { _,_ in }
            PageScripts.shared?.pushNow()
            guard let row = try? c.store.openTab(url: address,inSpace:c.currentSpaceID) else { check(false,"ytads-live: tab creation"); return done() }
            c.reloadAll(animated:false);c.show(row.id,focus:false)
            guard let tab = c.engineTab(for:row.id) else { check(false,"ytads-live: engine tab");return done() }
            for _ in 0..<150 {
                if await evaluate(tab,"document.readyState === 'complete'") as? Bool == true { break }
                try? await Task.sleep(nanoseconds:100_000_000)
            }
            try? await Task.sleep(nanoseconds:3_000_000_000)
            let consent = await evaluate(tab,"""
            (()=>{const b=[...document.querySelectorAll('button')].find(b=>b.textContent.trim()==='Reject all');
            if(b){b.click();return 'rejected';}return document.body.innerText.includes('Before you continue')?'unresolved':'absent';})()
            """)
            note("ytads-live: consent \(consent ?? "unknown")")
            try? await Task.sleep(nanoseconds:3_000_000_000)
            let before = await evaluate(tab,Self.videoAdsState)
            var samples: [[String:Any]] = []
            if isVideo {
                let play = "(()=>{const v=document.querySelector('video');if(!v||v.ended)return false;v.muted=true;if(v.paused)v.play().catch(()=>{});return true;})()"
                #if canImport(AircCore)
                if let engine = app.engine as? ChromiumEngine {
                    await withCheckedContinuation { resume in engine.devToolsCall("Runtime.evaluate",params:["expression":play,"userGesture":true],in:tab) { _,_ in resume.resume() } }
                } else { _ = await evaluate(tab,play) }
                #else
                _ = await evaluate(tab,play)
                #endif
                for _ in 0..<40 {
                    // Consent can arrive after readyState=complete and pause
                    // an earlier play. Match the baseline's muted play retry.
                    _ = await evaluate(tab,play)
                    if let state = await evaluate(tab,Self.videoAdsState) as? [String:Any] { samples.append(state) }
                    try? await Task.sleep(nanoseconds:500_000_000)
                }
            }
            let after = await evaluate(tab,Self.videoAdsState)
            await withCheckedContinuation { resume in captureNow("ytads-live-"+target) { resume.resume() } }
            var observations: [String:Any] = ["target":address,"consent":consent ?? NSNull(),"before":before ?? NSNull(),"after":after ?? NSNull(),"samples":samples,"blockedRequests":app.blocking.count(for:tab) ?? -1]
            if isVideo {
                let seek = await evaluate(tab,"(()=>{const v=document.querySelector('video');if(!v||!Number.isFinite(v.duration))return null;const to=Math.min(v.duration-1,Math.max(3,v.duration/2));v.currentTime=to;return to;})()")
                try? await Task.sleep(nanoseconds:2_000_000_000)
                observations["seekTarget"] = seek ?? NSNull()
                let seekState = await evaluate(tab,Self.videoAdsState) as? [String:Any]
                observations["afterSeek"] = seekState ?? [:]
                if let target = seek as? Double, let actual = seekState?["time"] as? Double {
                    check(actual >= target - 0.5 && actual < target + 5,"ytads-live: midpoint seek works")
                } else { check(false,"ytads-live: midpoint seek measurable") }
                let captionState = """
                (()=>{const b=document.querySelector('.ytp-subtitles-button'),p=document.querySelector('#movie_player');
                let listed=[];try{listed=p?.getOption?.('captions','tracklist')||[]}catch(_){}
                const metadata=window.ytInitialPlayerResponse?.captions?.playerCaptionsTracklistRenderer?.captionTracks||[];
                const tracks=Math.max(listed.length,metadata.length);
                return {available:tracks>0&&!!b&&getComputedStyle(b).display!=='none'&&b.getAttribute('aria-disabled')!=='true',
                tracks,button:b?.outerHTML||null,on:b?.getAttribute('aria-pressed'),text:[...document.querySelectorAll('.ytp-caption-segment')].map(e=>e.textContent).join(' ')}})()
                """
                let captionBefore = await evaluate(tab,captionState) as? [String:Any]
                observations["captionsBefore"] = captionBefore ?? [:]
                if captionBefore?["available"] as? Bool == true {
                    _ = await evaluate(tab,"document.querySelector('.ytp-subtitles-button').click();true")
                    try? await Task.sleep(nanoseconds:1_000_000_000)
                    let captionAfter = await evaluate(tab,captionState) as? [String:Any]
                    observations["captionsAfter"] = captionAfter ?? [:]
                    check(captionAfter?["on"] as? String != captionBefore?["on"] as? String,"ytads-live: available captions toggle")
                } else {
                    note("ytads-live: no offered caption tracks; local fixture covers caption cues")
                }
                let pip: Bool = await withCheckedContinuation { resume in app.engine.enterPictureInPictureForHost(tab) { _,opened in resume.resume(returning:opened) } }
                try? await Task.sleep(nanoseconds:500_000_000)
                let visible = await evaluate(tab,"(()=>{const v=document.querySelector('video');return !!document.pictureInPictureElement || v?.webkitPresentationMode === 'picture-in-picture';})()") as? Bool == true
                observations["pipOpened"] = pip || visible
                check(pip || visible,"ytads-live: native PiP opens")
                _ = await evaluate(tab,"(()=>{const v=document.querySelector('video');if(document.pictureInPictureElement)document.exitPictureInPicture();else if(v?.webkitPresentationMode==='picture-in-picture')v.webkitSetPresentationMode('inline');return true})()")
            }
            // JSON text normalizes optional PerformanceResourceTiming fields
            // that WebKit cannot always bridge as a nested native object.
            let requestJSON = await evaluate(tab, """
            JSON.stringify({observed:window.__ytadsTrace||[],resources:performance.getEntriesByType('resource')
              .filter(e=>['googlevideo','doubleclick','youtubei','/api/stats/ads','pagead'].some(p=>e.name.includes(p)))
              .map(e=>({url:e.name,type:e.initiatorType,duration:e.duration,bytes:e.transferSize}))})
            """) as? String
            let requests = requestJSON?.data(using:.utf8).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any]
            observations["requests"] = requests ?? [:]
            check(requests?["resources"] is [[String:Any]],"ytads-live: request observations captured")

            let early = await evaluate(tab,"window.__ytadsAdSamples || []") as? [[String:Any]] ?? []
            observations["documentStartAdSamples"] = early
            if let json=try? JSONSerialization.data(withJSONObject:observations,options:[.prettyPrinted,.sortedKeys]) {try? json.write(to:dir.appendingPathComponent("observations.json"))}
            // Assertions require observable playback, not merely a successful load.
            if let state = after as? [String:Any] {
                check(state["signedIn"] as? Bool == false,"ytads-live: no account signed in")
                check(state["consent"] as? Bool == false,"ytads-live: consent resolved at observation end")
                let slots = state["slots"] as? [[String:Any]] ?? []
                check(slots.allSatisfy { $0["visible"] as? Bool == false },"ytads-live: no visible ad slots")
                if isVideo {
                check(!early.isEmpty && early.allSatisfy { $0["ad"] as? Bool == false },"ytads-live: no pre-roll UI from document start")
                let times = samples.compactMap { $0["time"] as? Double }
                check((times.max() ?? 0) - (times.first ?? 0) > 1,"ytads-live: content advances")
                check(!samples.isEmpty && samples.allSatisfy { $0["adShowing"] as? Bool == false },"ytads-live: no ad UI throughout sampled playback")
                }
            } else { check(false,"ytads-live: page state available") }
            done()
        } }
    }
    private static let videoAdsState = #"""
    (()=>{const v=document.querySelector('video');return {url:location.href,title:document.title,
    time:v?.currentTime||0,duration:Number.isFinite(v?.duration)?v.duration:null,paused:v?.paused??true,
    error:v?.error?.code||null,adShowing:!!document.querySelector('.ad-showing,.ad-interrupting'),consent:!!document.body?.innerText.includes('Before you continue'),
    slots:[...document.querySelectorAll('ytd-ad-slot-renderer,ytd-display-ad-renderer,ytd-promoted-sparkles-web-renderer,ytd-promoted-video-renderer,ytd-search-pyv-renderer,#masthead-ad')].map(e=>({tag:e.tagName,visible:getComputedStyle(e).display!=='none'&&e.getBoundingClientRect().height>0})),
    signedIn:!!window.ytcfg?.get?.('LOGGED_IN'),captions:window.ytInitialPlayerResponse?.captions||null,
    tracks:v?[...v.textTracks].map(t=>({kind:t.kind,mode:t.mode,cues:t.cues?.length||0})):[],
    playerAdFields:['adPlacements','playerAds','adSlots'].filter(k=>k in (window.ytInitialPlayerResponse||{})),
    text:(document.body?.innerText||'').slice(0,8000)}})()
    """#
    private static let videoAdsObservationScript = #"""
    function install() {
      window.__ytadsTrace=[];performance.setResourceTimingBufferSize(5000);
      window.__ytadsAdSamples=[];
      const timer=setInterval(()=>{
        const reject=[...document.querySelectorAll('button')].find(b=>b.textContent.replace(/\s/g,'')==='Rejectall');
        if(reject&&reject.getBoundingClientRect().height>0)reject.click();
        const v=document.querySelector('video');
        window.__ytadsAdSamples.push({at:performance.now(),ad:!!document.querySelector('.ad-showing,.ad-interrupting'),time:v?.currentTime||0,signedIn:!!window.ytcfg?.get?.('LOGGED_IN')});
        if(window.__ytadsAdSamples.length>=400)clearInterval(timer);
      },250);
      const trace=(type,url,status)=>{if(window.__ytadsTrace.length<2000&&/googlevideo|doubleclick|youtubei|\/api\/stats\/ads|pagead/.test(String(url)))window.__ytadsTrace.push({type,url:String(url),status,time:performance.now()})};
      const fetch=window.fetch;window.fetch=function(...args){const url=args[0]?.url||args[0];trace('fetch',url,'start');return Reflect.apply(fetch,this,args).then(r=>{trace('fetch',url,r.status);return r},e=>{trace('fetch',url,'error');throw e})};
      const open=XMLHttpRequest.prototype.open, send=XMLHttpRequest.prototype.send, urls=new WeakMap();
      XMLHttpRequest.prototype.open=function(...a){const r=Reflect.apply(open,this,a);urls.set(this,a[1]);return r};
      XMLHttpRequest.prototype.send=function(...a){trace('xhr',urls.get(this),'start');this.addEventListener('loadend',()=>trace('xhr',urls.get(this),this.status),{once:true});return Reflect.apply(send,this,a)};
      return function(){clearInterval(timer)};
    }
    """#
}
#endif
