// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircDesign
import AircKit

extension SnapshotRunner {
    /// A standalone marketing part: every page and resource stays on loopback.
    func mkBlockingShots(video: Bool = false) {
        var server: LocalPageServer?
        var port: UInt16 = 0
        var id = ""
        run { [self] in
            NSApp.appearance = NSAppearance(named: .aqua)
            c.applyTranslucency(.off)
            c.window.setFrame(NSRect(x: -6000, y: -3000, width: 1440, height: 900), display: true)
        }
        step { done in
            server = LocalPageServer(pages: [:])
            guard let server else { return done() }
            server.start { port = $0 ?? 0; done() }
        }
        step { [self] done in
            guard port > 0, let server else { note("marketing: MISSING blocking: fixture server unavailable"); return done() }
            var page = Self.blockingDemo(port: port)
            if video {
                page = page.replacingOccurrences(of: "<title>Field Notes — A slower Sunday</title>", with: "<title>Field Notes — A quiet afternoon</title><script>var ytInitialPlayerResponse={playabilityStatus:{status:'OK'},videoDetails:{videoId:'fixture'},adPlacements:[{kind:'preroll'},{kind:'midroll'}]};</script>")
                    .replacingOccurrences(of: "A slower Sunday.", with: "A quiet afternoon.")
                    .replacingOccurrences(of: "Take the long way home. A small collection of paths, quiet places, and things worth noticing.", with: "A short film about taking the long way home.")
                    .replacingOccurrences(of: "Words by the Field Notes team · Illustration for this demo", with: "Illustration for this demo · Video ad protection")
                page += "<script>if(ytInitialPlayerResponse.adPlacements){document.querySelector('.landscape').textContent='Sponsored pre-roll';}else{document.querySelector('.landscape').insertAdjacentHTML('beforeend',`<div style='position:absolute;bottom:0;left:0;right:0;padding:16px;background:#223b2dcf;color:white;font:14px system-ui'>▶ &nbsp; A quiet afternoon &nbsp; ━━━━━━━━━━━ &nbsp; CC</div>`);}</script>"
            }
            server.handler = { path in
                if path == "/" { return .init(body: page) }
                if path.hasPrefix("/ads/") { return .init(headers: ["Content-Type": "text/javascript"], body: "window.adSeen=true;") }
                return .init(status: "404 Not Found", body: "")
            }
            MainActor.assumeIsolated {
                let pid = c.store.profile(ofSpace: c.currentSpaceID).id
                app?.blocking.installCheckRules("/ads/$script\nlocalhost##.sponsored\n" + (video ? "localhost##+js(airc-video-prune)\n" : ""), profile: pid, completion: done)
            }
        }
        run { [self] in
            guard let tab = try? c.store.openTab(url: "http://localhost:\(port)/", inSpace: c.currentSpaceID) else { return }
            id = tab.id; c.reloadAll(animated: false); c.show(id, focus: false)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: id)?.title == (video ? "Field Notes — A quiet afternoon" : "Field Notes — A slower Sunday") && self.c.engineTab(for: id)?.isLoading == false }, timeout: 12, then: done) }
        step { [self] done in
            Task { @MainActor in
                guard let tab = c.engineTab(for: id), let center = app?.blocking else {
                    note("marketing: MISSING blocking: fixture tab unavailable"); done(); return
                }
                let deadline = Date().addingTimeInterval(10)
                var protected = false
                while Date() < deadline {
                    let hidden: Bool = await withCheckedContinuation { resume in
                        tab.evaluate("!!document.querySelector('.sponsored') && getComputedStyle(document.querySelector('.sponsored')).display === 'none' && !window.adSeen") {
                            resume.resume(returning: $0 as? Bool == true)
                        }
                    }
                    var pruned = true
                    if video {
                        pruned = await withCheckedContinuation { resume in
                            tab.evaluate("!!window.ytInitialPlayerResponse && !('adPlacements' in ytInitialPlayerResponse)") { resume.resume(returning: $0 as? Bool == true) }
                        }
                    }
                    if hidden && pruned && center.count(for: tab) == 8 && center.failures.isEmpty { protected = true; break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if protected { note("marketing: blocking verified eight network blocks and cosmetic hiding") }
                else { note("marketing: MISSING blocking: protection did not settle; count=\(center.count(for: tab).map(String.init) ?? "unavailable"), failures=\(center.failures)") }
                done()
            }
        }
        run { [self] in c.showSiteControls() }
        wait(0.4)
        mkWindowShot(video ? "video-blocking" : "blocking")
        run { [self] in
            c.closeSiteControls(animated: false); server?.stop()
            NSApp.appearance = nil
            note("marketing: \(video ? "video-blocking" : "blocking") done")
        }
    }
    private static func blockingDemo(port: UInt16) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>Field Notes — A slower Sunday</title>
        <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 40 40'%3E%3Crect width='40' height='40' rx='10' fill='%234e6b54'/%3E%3Cpath d='M11 28V12h18M11 20h13' stroke='%23fff' stroke-width='3' fill='none'/%3E%3C/svg%3E">
        <style>*{box-sizing:border-box}body{margin:0;background:#f7f6ef;color:#283b2d;font:18px Georgia,serif}nav{padding:28px 7%;border-bottom:1px solid #d8ddcf;font:14px system-ui;display:flex;justify-content:space-between}b{letter-spacing:.16em}main{max-width:920px;margin:58px auto}small{font:12px system-ui;letter-spacing:.15em;color:#738069}h1{font:64px Georgia;letter-spacing:-2px;margin:24px 0}p{font-size:21px;line-height:1.65;max-width:680px;color:#68725f}.landscape{height:270px;border-radius:8px;overflow:hidden;background:#ced8ba;margin:36px 0;position:relative}.hill{position:absolute;width:800px;height:330px;border-radius:50%;background:#a6ba87;left:-80px;top:120px;transform:rotate(-12deg)}.back{left:400px;top:80px;background:#6e8c61}.sun{position:absolute;right:160px;top:42px;width:72px;height:72px;border-radius:50%;background:#f9e7ab}footer{font:13px system-ui;color:#7d8672;margin-top:22px}.sponsored{padding:24px;background:#ffdca0}</style>
        <nav><b>FIELD NOTES</b><span>Stories &nbsp;&nbsp; Places &nbsp;&nbsp; About</span></nav>
        <main><small>THE WEEKEND EDIT &nbsp; / &nbsp; 6 MIN READ</small><h1>A slower Sunday.</h1><p>Take the long way home. A small collection of paths, quiet places, and things worth noticing.</p><div class="landscape"><div class="sun"></div><div class="hill back"></div><div class="hill"></div></div><div class="sponsored">Sponsored content</div><p>Some mornings are better without a plan. Follow the river, find a bench in the sun, and leave a little room for surprise.</p><footer>Words by the Field Notes team · Illustration for this demo</footer></main>
        \((1...8).map { "<script src='/ads/slot-\($0).js'></script>" }.joined())
        """
    }
}
#endif
