// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

#if canImport(AircCore)
/// `--script drmwebkit` and `--script drmwebkit-read` (Chromium; docs/user/protected-media.md): DRM services' pages in
/// WebKit inside the Chromium build, on loopback pages, no account, no capture device. "localhost" plays the part of a
/// listed service (ProtectedMedia.testHosts); pages on 127.0.0.1 are another site of the same server, Chromium's.
///   - a listed host opens in WebKit with Safari's user agent and its toast; find, zoom, a download and the media tray
///     work on it; its popup stays WebKit;
///   - a Chromium page's popup to the listed host stays Chromium; its target=_blank link opens a WebKit tab;
///   - a split with one engine per pane; the Chromium pane's link hands off in place (same tab, pane, focus);
///   - the URL bar picks again; a redirect after a GET moves to WebKit; a POST's result stays in Chromium; a WebKit
///     page's own link stays WebKit; Little Arc; the setting off;
///   - `drmwebkit-read` (the same data folder, relaunched): the tab comes back in WebKit and its cookie is still there;
///     the profile's store is then deleted.
extension SnapshotRunner {
    func drmWebKitScenario(read: Bool) {
        guard let engine = app?.engine as? ChromiumEngine else { return run { self.note("drmwebkit: Chromium only") } }
        let tag = "drmwebkit"
        var server: LocalPageServer?
        var port: UInt16 = 0
        let listed = { (path: String) in "http://localhost:\(port)\(path)" }
        let other = { (path: String) in "http://127.0.0.1:\(port)\(path)" }
        var web = "", chromium = ""
        func page(_ id: String) -> EngineTab? { c.engineTab(for: id) }
        func isWebKit(_ id: String) -> Bool { ProtectedMedia.isWebKitPage(page(id)) }
        func eval(_ id: String, _ js: String, _ then: @escaping (Any?) -> Void) {
            guard let p = page(id) else { return then(nil) }
            p.evaluate(js, completion: then)
        }
        let servicePage = """
            <title>service</title><p>needle and another needle</p>
            <p><a id="out">a link out</a> <a id="dl" href="/file.txt" download>file</a></p>
            <button id="pop" onclick="window.open(location.protocol + '//127.0.0.1:' + location.port + '/popup', 'wpop', 'width=420,height=320')">popup</button>
            <script>document.getElementById('out').href = location.protocol + '//127.0.0.1:' + location.port + '/chromium?from=webkit'</script>
            """
        let chromiumPage = """
            <title>chromium</title>
            <p><a id="in" style="display:block;width:220px;height:30px">in place</a></p>
            <p><a id="blank" target="_blank" style="display:block;width:220px;height:30px">new tab</a></p>
            <button id="pop" style="width:220px;height:30px">popup</button>
            <form method="post" id="f"><input type="hidden" name="a" value="1"></form>
            <script>
            var s = location.protocol + '//localhost:' + location.port;
            document.getElementById('in').href = s + '/service?from=link';
            document.getElementById('blank').href = s + '/service?from=blank';
            document.getElementById('f').action = s + '/posted';
            document.getElementById('pop').onclick = function () { window.open(s + '/service?from=popup', 'cpop', 'width=420,height=320') };
            </script>
            """

        step { [self] done in
            ProtectedMedia.shared.testHosts = ["localhost"]
            WebKitLibrary.directoryOverride = dir.appendingPathComponent("drm-downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: WebKitLibrary.directoryOverride!, withIntermediateDirectories: true)
            server = LocalPageServer(responses: [
                "/service": .init(body: servicePage),
                "/chromium": .init(body: chromiumPage),
                "/popup": .init(body: "<title>popup</title><p>a popup</p>"),
                "/posted": .init(body: "<title>posted</title><p>a form's result</p>"),
                "/file.txt": .init(headers: ["Content-Type": "text/plain", "Content-Disposition": "attachment; filename=\"drm-test.txt\""],
                                   body: "drm test file"),
            ])
            server?.handler = { path in
                // The redirect needs the port, known once the server listens.
                path == "/redirect" ? .init(status: "302 Found", headers: ["Location": listed("/service?from=redirect")], body: "") : nil
            }
            guard let server else { check(false, "\(tag): the loopback server starts"); return done() }
            server.start { p in
                port = p ?? 0
                done()
            }
        }

        /// A click on element `id` of a Chromium page, as the person's (DevTools Runtime.evaluate with a user gesture: a
        /// link click is then a renderer-initiated link navigation with a gesture, window.open isn't blocked). Synthesized
        /// mouse input doesn't reach a background window's page on a Mac in use.
        func click(_ id: @escaping @autoclosure () -> String, element: String) {
            step { [self] done in
                guard let p = page(id()) else { return done() }
                engine.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('\(element)').click(); true",
                                                                 "userGesture": true, "returnByValue": true], in: p) { _, error in
                    if let error { self.note("\(tag): the click on \(element) failed: \(error)") }
                    done()
                }
            }
        }
        func waitLoaded(_ id: @escaping @autoclosure () -> String, title: String, timeout: Double = 8) {
            step { [self] done in waitUntil({ page(id())?.title == title && page(id())?.isLoading == false }, timeout: timeout) { done() } }
        }
        /// `url` is made when the step runs (the port is known by then).
        func openTab(_ url: @escaping @autoclosure () -> String, _ set: @escaping (String) -> Void) {
            run { [self] in
                let url = url()
                guard port != 0, let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID) else {
                    return check(false, "\(tag): a tab for \(url)")
                }
                set(t.id)
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
        }

        if read {
            drmWebKitRead(engine: engine, port: { port }, listed: listed)
            run { server?.stop() }   // also keeps the server alive until here
            return
        }
        var probe = ""
        openTab(other("/chromium?probe")) { probe = $0 }
        waitLoaded(probe, title: "chromium")
        // A listed host opens in WebKit, with Safari's user agent and its toast.
        openTab(listed("/service")) { web = $0 }
        waitLoaded(web, title: "service")
        step { [self] done in
            eval(web, "navigator.userAgent") { ua in
                let ua = ua as? String ?? ""
                self.check(isWebKit(web), "\(tag): a listed host opens in WebKit (\(isWebKit(web)))")
                self.check(ua.contains("Safari/605.1.15") && ua.contains("Version/") && !ua.contains("Chrome/"),
                           "\(tag): Safari's user agent (\(ua))")
                self.check(self.c.protectedMediaToast?.service == "localhost",
                           "\(tag): the toast says it plays with Safari's engine (\(self.c.protectedMediaToast?.service ?? "none"))")
                done()
            }
        }
        capture("drmwebkit-toast")
        // Cookies for the relaunch.
        step { [self] done in
            eval(web, "document.cookie = 'drm=kept; max-age=86400; path=/'; document.cookie") { v in
                self.check((v as? String)?.contains("drm=kept") == true, "\(tag): a WebKit page keeps a cookie (\(v as? String ?? "nil"))")
                done()
            }
        }
        // Find and zoom.
        step { [self] done in
            guard let p = page(web) else { return done() }
            p.find("needle", forward: true) { found, count in
                self.check(found && count == 2, "\(tag): find on a WebKit page (found \(found), \(count.map(String.init) ?? "?") matches)")
                p.stopFinding()
                p.zoom(step: 1)
                let zoomed = p.zoomFactor
                p.zoom(step: 0)
                self.check(zoomed > 1.05 && abs(p.zoomFactor - 1) < 0.01, "\(tag): zoom on a WebKit page (\(zoomed), back to \(p.zoomFactor))")
                done()
            }
        }
        // The app's page script (Boosts, the Widevine probe) runs on WebKit pages too.
        step { [self] done in
            eval(web, "typeof window.__aircPageReceive") { v in
                self.check(v as? String == "function", "\(tag): the page script reaches WebKit pages (receive is \(v as? String ?? "nil"))")
                done()
            }
        }
        // A download lands in the profile's downloads list.
        run { eval(web, "document.getElementById('dl').click(); true") { _ in } }
        step { [self] done in
            let profile = page(web)?.profile
            let row = { profile.flatMap { p in engine.downloadItems(in: p).first { $0.fileName.hasPrefix("drm-test") } } }
            waitUntil({ row()?.state == .complete }, timeout: 8) {
                self.check(row()?.state == .complete, "\(tag): a WebKit page's download is in the profile's list (\(row().map { "\($0.fileName) \($0.state)" } ?? "none"))")
                done()
            }
        }
        // The media tray: a muted video from a canvas stream (no file, no device), with a Media Session title.
        run {
            eval(web, """
            (function(){ var c = document.createElement('canvas'); c.width = 64; c.height = 36; var g = c.getContext('2d'), n = 0;
              setInterval(function(){ g.fillStyle = 'hsl(' + (n++ * 7 % 360) + ',60%,50%)'; g.fillRect(0, 0, 64, 36); }, 100);
              // Unmuted (the tray ignores muted media) and silent: the stream has no audio track.
              var v = document.createElement('video'); v.playsInline = true; v.srcObject = c.captureStream(10);
              document.body.appendChild(v); window.__drmAudio = v;
              navigator.mediaSession.metadata = new MediaMetadata({title: 'DRM test', artist: 'Airc'});
              v.play(); return true; })()
            """) { _ in }
        }
        wait(1)
        step { [self] done in
            let session = { MediaLibrary.shared.media?.sessions[web] }
            waitUntil({ session() != nil }, timeout: 8) {
                self.check(session() != nil, "\(tag): the media center has the WebKit page's session (\(session() != nil))")
                done()
            }
        }
        // The tray shows players of tabs that aren't on screen.
        run { [self] in c.show(probe, focus: false) }
        step { [self] done in
            let player = { MediaLibrary.shared.media?.players.first { $0.tabID == web } }
            waitUntil({ player() != nil }, timeout: 8) {
                self.check(player() != nil, "\(tag): the media tray shows the WebKit page while another tab is shown (\(player() != nil))")
                eval(web, "window.__drmAudio && window.__drmAudio.pause(); true") { _ in done() }
            }
        }
        run { [self] in c.show(web, focus: false) }
        // Its popup keeps WebKit (not listed, but its opener's engine).
        var popup = ""
        step { [self] done in
            let before = Set(c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id))
            eval(web, "document.getElementById('pop').click(); true") { _ in
                self.waitUntil({ self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).contains { !before.contains($0.id) && $0.url.contains("/popup") } }, timeout: 6) {
                    popup = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).first { !before.contains($0.id) }?.id ?? ""
                    self.check(!popup.isEmpty && isWebKit(popup), "\(tag): a WebKit page's popup keeps WebKit (\(popup.isEmpty ? "no popup" : isWebKit(popup) ? "WebKit" : "Chromium"))")
                    done()
                }
            }
        }
        run { [self] in if !popup.isEmpty { c.closeTab(popup) } }

        // A Chromium page.
        openTab(other("/chromium")) { chromium = $0 }
        waitLoaded(chromium, title: "chromium")
        run { [self] in check(!isWebKit(chromium) && page(chromium) != nil, "\(tag): another site opens in Chromium") }
        // Its popup to the listed host stays Chromium.
        var cpop = ""
        var before = Set<String>()
        run { [self] in before = Set(c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id)) }
        click(chromium, element: "pop")
        step { [self] done in
            waitUntil({ self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).contains { !before.contains($0.id) } }, timeout: 6) {
                cpop = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).first { !before.contains($0.id) }?.id ?? ""
                done()
            }
        }
        wait(1.5)   // past its commit: the redirect fallback must leave a popup alone
        run { [self] in
            check(!cpop.isEmpty && !isWebKit(cpop) && page(cpop)?.url?.host == "localhost",
                  "\(tag): a Chromium page's popup to a listed site keeps Chromium (\(cpop.isEmpty ? "no popup" : isWebKit(cpop) ? "WebKit" : "Chromium") \(page(cpop)?.url?.absoluteString ?? ""))")
            if !cpop.isEmpty { c.closeTab(cpop) }
            c.show(chromium, focus: false)
            before = Set(c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id))
        }
        // Its target=_blank link to the listed host opens a WebKit tab, in the opener's Space.
        click(chromium, element: "blank")
        step { [self] done in
            let new = { self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).first { !before.contains($0.id) }?.id }
            waitUntil({ new().map { isWebKit($0) && page($0)?.url?.query == "from=blank" } ?? false }, timeout: 6) {
                let id = new()
                self.check(id.map(isWebKit) == true, "\(tag): a Chromium page's new-tab link to a listed site opens in WebKit (\(id.map { isWebKit($0) ? "WebKit" : "Chromium" } ?? "no tab"))")
                if let id { self.c.closeTab(id) }
                done()
            }
        }

        // A split with one engine per pane.
        var split = ""
        run { [self] in
            guard let x = try? c.store.createSplit([chromium, web], inSpace: c.currentSpaceID, focused: chromium) else {
                return check(false, "\(tag): a split of the two")
            }
            split = x.id
            c.show(chromium, focus: false)
        }
        wait(0.6)
        func inPane(_ id: String) -> Bool {
            guard let p = page(id), let host = c.splitContainer.pane(for: id)?.host else { return false }
            return p.view.isDescendant(of: host) && !p.view.isHidden
        }
        run { [self] in
            check(c.shownSplitID == split && inPane(chromium) && inPane(web) && !isWebKit(chromium) && isWebKit(web),
                  "\(tag): a split with Chromium and WebKit panes (shown \(c.shownSplitID == split), Chromium pane \(inPane(chromium)), WebKit pane \(inPane(web)))")
        }
        capture("drmwebkit-split")
        // The Chromium pane's own link to the listed host: WebKit, in place.
        var replaced: EngineTab?
        run { [self] in replaced = page(chromium) }
        click(chromium, element: "in")
        step { [self] done in
            waitUntil({ isWebKit(chromium) && page(chromium)?.url?.query == "from=link" }, timeout: 8) {
                let x = self.c.store.split(split)
                self.check(isWebKit(chromium) && replaced?.isClosed != false,
                           "\(tag): a Chromium page's link to a listed site opens again in WebKit (\(isWebKit(chromium)), old page closed \(replaced?.isClosed ?? false))")
                self.check(x?.tabIDs == [chromium, web] && self.c.shownSplitID == split && self.c.shownTabID == chromium && inPane(chromium),
                           "\(tag): the handoff keeps the split, its pane and its focus (panes \(x?.tabIDs == [chromium, web]), focus \(self.c.shownTabID == chromium), in its pane \(inPane(chromium)))")
                done()
            }
        }
        capture("drmwebkit-handoff")
        // The URL bar picks again: WebKit → Chromium in place.
        run { [self] in
            c.focusSplitPane(chromium)
            c.navigate(to: URL(string: other("/chromium?from=urlbar"))!, newTab: false)
        }
        step { [self] done in
            waitUntil({ !isWebKit(chromium) && page(chromium)?.title == "chromium" }, timeout: 8) {
                self.check(!isWebKit(chromium) && inPane(chromium), "\(tag): the URL bar takes a WebKit page back to Chromium, in its pane (\(!isWebKit(chromium)))")
                done()
            }
        }
        // A redirect after a GET (the URL bar's) lands on the listed host: WebKit.
        run { [self] in c.navigate(to: URL(string: other("/redirect"))!, newTab: false) }
        step { [self] done in
            waitUntil({ isWebKit(chromium) && page(chromium)?.url?.query == "from=redirect" }, timeout: 8) {
                self.check(isWebKit(chromium), "\(tag): a redirect to a listed site moves the page to WebKit (\(page(chromium)?.url?.absoluteString ?? ""))")
                done()
            }
        }
        // A form's POST result on the listed host stays in Chromium.
        run { [self] in c.navigate(to: URL(string: other("/chromium?from=post"))!, newTab: false) }
        waitLoaded(chromium, title: "chromium")
        wait(0.5)
        run { eval(chromium, "document.getElementById('f').submit(); true") { _ in } }
        step { [self] done in waitUntil({ page(chromium)?.title == "posted" }, timeout: 8) { done() } }
        wait(1.5)
        run { [self] in
            check(page(chromium)?.title == "posted" && !isWebKit(chromium),
                  "\(tag): a POST's result on a listed site stays in Chromium (\(page(chromium)?.title ?? "?"), \(isWebKit(chromium) ? "WebKit" : "Chromium"))")
        }
        // A WebKit page's own link to another site stays WebKit.
        run { eval(web, "document.getElementById('out').click(); true") { _ in } }
        step { [self] done in
            waitUntil({ page(web)?.url?.host == "127.0.0.1" && page(web)?.isLoading == false }, timeout: 8) {
                self.check(isWebKit(web) && page(web)?.url?.host == "127.0.0.1",
                           "\(tag): a WebKit page's own link stays WebKit (\(isWebKit(web)), \(page(web)?.url?.absoluteString ?? ""))")
                done()
            }
        }
        // Little Arc opens a listed site in WebKit.
        var little: LittleArcController?
        run { [self] in little = app?.openLittleArc(url: URL(string: listed("/service?from=littlearc"))) }
        step { [self] done in
            waitUntil({ little?.page?.title == "service" }, timeout: 8) {
                self.check(ProtectedMedia.isWebKitPage(little?.page), "\(tag): Little Arc opens a listed site in WebKit (\(ProtectedMedia.isWebKitPage(little?.page)))")
                let page = little?.page
                little?.window.performClose(nil)
                self.waitUntil({ little?.window.isVisible == false }, timeout: 5) {
                    self.check(little?.window.isVisible == false && page?.isClosed == true,
                               "\(tag): Little Arc closes with its WebKit page (window closed \(little?.window.isVisible == false), page closed \(page?.isClosed ?? false))")
                    done()
                }
            }
        }
        // The setting off: a new page is Chromium's.
        var off = ""
        run { [self] in app?.settings.values.webKitProtectedMedia = false }
        openTab(listed("/service?from=off")) { off = $0 }
        waitLoaded(off, title: "service")
        run { [self] in
            check(!isWebKit(off) && page(off) != nil, "\(tag): with the setting off a listed site opens in Chromium (\(isWebKit(off) ? "WebKit" : "Chromium"))")
            app?.settings.values.webKitProtectedMedia = true
            c.closeTab(off)
        }
        // Site Controls' "Safari's engine" switch: on a Chromium page that asked for Widevine, then back.
        run { [self] in c.show(probe, focus: false); page(probe)?.reload() }
        waitLoaded(probe, title: "chromium")
        run { [self] in
            // From the page's own main world, as a player calls it (evaluate runs in another world).
            eval(probe, """
            var s = document.createElement('script');
            s.textContent = "navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{initDataTypes: ['cenc'], " +
              "videoCapabilities: [{contentType: 'video/mp4; codecs=\\"avc1.42E01E\\"'}]}]).catch(function(){})";
            document.head.appendChild(s); true
            """) { _ in }
        }
        step { [self] done in waitUntil({ ProtectedMedia.shared.askedForWidevine(page(probe)) }, timeout: 5) { done() } }
        run { [self] in
            c.showSiteControls()
            let m = c.siteControls?.model
            check(ProtectedMedia.shared.askedForWidevine(page(probe)) && m?.showsSafariEngine == true && m?.usesSafariEngine == false,
                  "\(tag): Site Controls offers Safari's engine on a page that asked for Widevine (asked \(ProtectedMedia.shared.askedForWidevine(page(probe))), switch \(m?.showsSafariEngine ?? false))")
            m?.safariEngine.wrappedValue = true
        }
        step { [self] done in
            waitUntil({ isWebKit(probe) && page(probe)?.isLoading == false }, timeout: 8) {
                self.check(isWebKit(probe) && ProtectedMedia.shared.choices.added == ["127.0.0.1"],
                           "\(tag): the switch opens the site with Safari's engine (\(isWebKit(probe)), added \(ProtectedMedia.shared.choices.added))")
                done()
            }
        }
        capture("drmwebkit-sitecontrols")
        run { [self] in
            c.showSiteControls()
            let m = c.siteControls?.model
            check(m?.showsSafariEngine == true && m?.usesSafariEngine == true, "\(tag): Site Controls shows the switch on on a WebKit page")
            check(m?.permissionsAvailable == false && m?.permissions.isEmpty == true,
                  "\(tag): Site Controls lists no Chromium permissions on a WebKit page (\(m?.permissions.count ?? -1) listed)")
            m?.safariEngine.wrappedValue = false
        }
        step { [self] done in
            waitUntil({ !isWebKit(probe) && page(probe)?.isLoading == false }, timeout: 8) {
                self.check(!isWebKit(probe) && ProtectedMedia.shared.choices.added.isEmpty,
                           "\(tag): the switch sends the site back to Chromium (\(!isWebKit(probe)), added \(ProtectedMedia.shared.choices.added))")
                done()
            }
        }
        // For the relaunch: the WebKit tab on its listed page.
        run { [self] in
            c.closeTab(chromium)
            c.navigate(to: URL(string: listed("/service?from=persist"))!, newTab: true)
        }
        // WebKit writes cookies to disk on its own schedule: time for it before the quit.
        wait(3)
        run { server?.stop() }
    }

    /// `--script fairplay` (Chromium, network): EZDRM's public FairPlay test stream (HLS, SAMPLE-AES) plays, muted, in a
    /// WebKit page of the Chromium build: key system access, the server certificate, a licence request, the licence
    /// (a CKC from EZDRM's demo server), usable keys and advancing time. The page is a loopback page listed as a
    /// service ("localhost", AIRC_WEBKIT_HOSTS); no account, no device.
    func fairPlayScenario() {
        guard app?.engine is ChromiumEngine else { return run { self.note("fairplay: Chromium only") } }
        let tag = "fairplay"
        var server: LocalPageServer?
        var port: UInt16 = 0
        var tabID = ""
        let player = """
            <title>fairplay</title><video id="v" muted playsinline style="width:640px;height:360px;background:#000"></video><pre id="log"></pre>
            <script>
            var fp = window.__fp = {stage: 'start', log: []};
            function note(s) { fp.log.push(s); document.getElementById('log').textContent = fp.log.join('\\n'); }
            var base = 'https://fps.ezdrm.com', stream = base + '/demo/video/ezdrm.m3u8', cert = base + '/demo/video/eleisure.cer',
                licence = base + '/api/licenses/09cc0377-6dd4-40cb-b09d-b582236e70fe';
            (async function () {
              var v = document.getElementById('v');
              v.muted = true;
              try {
                var access = await navigator.requestMediaKeySystemAccess('com.apple.fps', [{ initDataTypes: ['skd', 'sinf'],
                  videoCapabilities: [{ contentType: 'application/vnd.apple.mpegurl', robustness: '' }],
                  audioCapabilities: [{ contentType: 'application/vnd.apple.mpegurl', robustness: '' }] }]);
                fp.access = access.keySystem; note('access ' + access.keySystem);
                var keys = await access.createMediaKeys();
                var c = new Uint8Array(await (await fetch(cert)).arrayBuffer());
                fp.certificate = c.byteLength; note('certificate ' + c.byteLength + ' bytes');
                await keys.setServerCertificate(c);
                await v.setMediaKeys(keys);
                v.addEventListener('encrypted', async function (e) {
                  fp.encrypted = e.initDataType; note('encrypted ' + e.initDataType + ' ' + e.initData.byteLength + ' bytes');
                  var session = keys.createSession();
                  session.addEventListener('message', async function (m) {
                    fp.request = m.message.byteLength; note('licence request ' + m.message.byteLength + ' bytes');
                    var r = await fetch(licence, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: m.message });
                    var ckc = new Uint8Array(await r.arrayBuffer());
                    fp.licence = r.status + ' ' + ckc.byteLength; note('licence ' + r.status + ', ' + ckc.byteLength + ' bytes');
                    try { await session.update(ckc); note('licence accepted'); } catch (x) { fp.error = 'update ' + x; note(fp.error); }
                  });
                  session.addEventListener('keystatuseschange', function () {
                    var st = []; session.keyStatuses.forEach(function (s) { st.push(s); }); fp.keys = st.join(','); note('keys ' + fp.keys);
                  });
                  try { await session.generateRequest(e.initDataType, e.initData); } catch (x) { fp.error = 'generateRequest ' + x; note(fp.error); }
                });
                v.addEventListener('error', function () {
                  note('modern EME: video error ' + (v.error && v.error.code));
                  if (!fp.encrypted && window.WebKitMediaKeys) legacy(c); else fp.error = 'video error ' + (v.error && v.error.code);
                });
                v.src = stream;
                v.play().then(function () { note('playing'); }, function (x) { note('play: ' + x); });
              } catch (x) { fp.error = String(x); note('error ' + x); }
            })();
            // Apple's legacy FairPlay API (WebKitMediaKeys), as Apple's and EZDRM's HTML5 samples use it for HLS.
            function legacy(cert) {
              fp.api = 'legacy'; note('legacy WebKitMediaKeys');
              var old = document.getElementById('v'), v = document.createElement('video');
              v.id = 'v'; v.muted = true; v.playsInline = true; v.style.cssText = old.style.cssText; old.replaceWith(v);
              function u16(s) { var a = new Uint16Array(s.length); for (var i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a; }
              v.addEventListener('webkitneedkey', function (e) {
                var uri = String.fromCharCode.apply(null, new Uint16Array(e.initData.buffer, e.initData.byteOffset, e.initData.byteLength / 2));
                uri = uri.slice(uri.indexOf('skd://'));
                var id = u16(uri.slice(6)), size = e.initData.byteLength + 4 + id.byteLength + 4 + cert.byteLength;
                var buf = new ArrayBuffer(size), d = new DataView(buf), o = 0;
                new Uint8Array(buf, o, e.initData.byteLength).set(e.initData); o += e.initData.byteLength;
                d.setUint32(o, id.byteLength, true); o += 4; new Uint8Array(buf, o, id.byteLength).set(new Uint8Array(id.buffer)); o += id.byteLength;
                d.setUint32(o, cert.byteLength, true); o += 4; new Uint8Array(buf, o, cert.byteLength).set(cert);
                fp.encrypted = 'skd (legacy)'; note('needkey ' + uri);
                if (!v.webkitKeys) v.webkitSetMediaKeys(new WebKitMediaKeys('com.apple.fps.1_0'));
                var session = v.webkitKeys.createSession('video/mp4', new Uint8Array(buf));
                session.addEventListener('webkitkeymessage', async function (m) {
                  fp.request = m.message.byteLength; note('licence request ' + m.message.byteLength + ' bytes');
                  var r = await fetch(licence, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: m.message });
                  var ckc = new Uint8Array(await r.arrayBuffer());
                  fp.licence = r.status + ' ' + ckc.byteLength; note('licence ' + r.status + ', ' + ckc.byteLength + ' bytes');
                  session.update(ckc);
                });
                session.addEventListener('webkitkeyadded', function () { fp.keys = 'usable'; note('key added'); });
                session.addEventListener('webkitkeyerror', function () { fp.error = 'key error ' + (session.error && session.error.code); note(fp.error); });
              });
              v.addEventListener('error', function () { fp.error = 'legacy video error ' + (v.error && v.error.code); note(fp.error); });
              v.src = stream;
              v.play().then(function () { note('playing (legacy)'); }, function (x) { note('play: ' + x); });
            }
            setInterval(function () { var v = document.getElementById('v'); fp.time = v.currentTime; fp.ready = v.readyState;
              fp.size = v.videoWidth + 'x' + v.videoHeight; fp.paused = v.paused; v.muted = true; }, 250);
            </script>
            """
        step { [self] done in
            server = LocalPageServer(responses: ["/fairplay": .init(body: player)])
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in
            guard port != 0, let t = try? c.store.openTab(url: "http://localhost:\(port)/fairplay", inSpace: c.currentSpaceID) else {
                return check(false, "\(tag): a tab for the player")
            }
            tabID = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        var state: [String: Any] = [:]
        step { [self] done in
            func poll(_ left: Int) {
                c.engineTab(for: tabID)?.evaluate("JSON.stringify(window.__fp || {})") { v in
                    state = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    let time = (state["time"] as? NSNumber)?.doubleValue ?? 0
                    if time > 4 || state["error"] != nil || left == 0 { return done() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll(left - 1) }
                }
            }
            poll(90)
        }
        capture("fairplay")
        run { [self] in
            let page = c.engineTab(for: tabID)
            let time = (state["time"] as? NSNumber)?.doubleValue ?? 0
            note("\(tag): \((state["log"] as? [String] ?? []).joined(separator: " | "))")
            check(ProtectedMedia.isWebKitPage(page), "\(tag): the player is a WebKit page")
            check(state["access"] as? String == "com.apple.fps" && (state["certificate"] as? NSNumber).map { $0.intValue > 0 } == true
                  && (state["licence"] as? String)?.hasPrefix("200") == true && (state["keys"] as? String)?.contains("usable") == true,
                  "\(tag): FairPlay key system, certificate, licence and usable keys (access \(state["access"] ?? "-"), licence \(state["licence"] ?? "-"), keys \(state["keys"] ?? "-"))")
            check(time > 4 && state["paused"] as? Bool == false && state["error"] == nil,
                  "\(tag): EZDRM's FairPlay stream plays (time \(String(format: "%.2f", time)) s, \(state["size"] ?? "?"), ready \(state["ready"] ?? "?"), error \(state["error"] ?? "none"))")
            page?.evaluate("document.getElementById('v').pause(); true", completion: nil)
            server?.stop()
        }
    }

    /// `--script drmservices` (Chromium, network, logged out, never signing in): the real services' pages open in WebKit
    /// and say nothing like "browser not supported". Muted; each page's picture is kept for the record.
    func drmServicesScenario() {
        guard app?.engine is ChromiumEngine else { return run { self.note("drmservices: Chromium only") } }
        let tag = "drmservices"
        let sites = ["https://open.spotify.com/", "https://www.netflix.com/", "https://www.disneyplus.com/", "https://www.max.com/",
                     "https://tv.apple.com/", "https://music.apple.com/", "https://www.primevideo.com/", "https://listen.tidal.com/"]
        let refusal = "browser (is |isn.t |not )?(not )?supported|unsupported browser|(update|upgrade) your browser|switch to a supported browser"
            + "|protected content|enable drm|not available (on|in) this browser|isn.t available (on|in) this browser|Widevine"
        for (i, site) in sites.enumerated() {
            var id = ""
            run { [self] in
                guard let t = try? c.store.openTab(url: site, inSpace: c.currentSpaceID) else { return check(false, "\(tag): a tab for \(site)") }
                id = t.id
                try? c.store.setMuted(t.id, true)
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            step { [self] done in
                // Muted all along: nothing plays out loud on the Mac.
                let mute = "document.querySelectorAll('video,audio').forEach(function(m){ m.muted = true; m.pause && m.autoplay && m.pause(); }); true"
                let start = Date()
                func poll() {
                    let p = c.engineTab(for: id)
                    p?.evaluate(mute, completion: nil)
                    if Date().timeIntervalSince(start) > 12 && p?.isLoading == false || Date().timeIntervalSince(start) > 25 { return done() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
                }
                poll()
            }
            step { [self] done in
                let p = c.engineTab(for: id)
                let js = "(function(){ var t = (document.body && document.body.innerText) || ''; var m = t.match(new RegExp(\(String(reflecting: refusal)), 'i'));"
                    + " return JSON.stringify({title: document.title, url: location.href, refusal: m ? m[0] : '', length: t.length}); })()"
                p?.evaluate(js) { v in
                    let d = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                    let webKit = ProtectedMedia.isWebKitPage(p)
                    let refused = d["refusal"] as? String ?? "?"
                    self.check(webKit && refused.isEmpty && (d["length"] as? NSNumber)?.intValue ?? 0 > 0,
                               "\(tag): \(site) opens in \(webKit ? "WebKit" : "Chromium"), \(d["url"] ?? "?") \"\(d["title"] ?? "")\", "
                               + "refusal \(refused.isEmpty ? "none" : "\"\(refused)\"") (\(d["length"] ?? 0) characters)")
                    done()
                }
            }
            capture("drmservice-\(i)-" + (URL(string: site)?.host ?? "site"))
            run { [self] in c.closeTab(id) }
        }
    }

    private func drmWebKitRead(engine: ChromiumEngine, port: @escaping () -> UInt16, listed: @escaping (String) -> String) {
        let tag = "drmwebkit-read"
        var id = ""
        run { [self] in
            let t = c.store.todayTabs(ofSpace: c.currentSpaceID).first { $0.url.contains("from=persist") }
            guard let t else { return check(false, "\(tag): the WebKit tab is still there after the relaunch") }
            id = t.id
            c.show(t.id, focus: false)
        }
        wait(1)
        run { [self] in
            check(ProtectedMedia.isWebKitPage(c.engineTab(for: id)), "\(tag): the restored tab is WebKit again (\(ProtectedMedia.isWebKitPage(c.engineTab(for: id))))")
            c.navigate(to: URL(string: listed("/service?from=read"))!, newTab: false)
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: id)?.title == "service" && self.c.engineTab(for: id)?.isLoading == false }, timeout: 8) { done() } }
        wait(1)
        step { [self] done in
            c.engineTab(for: id)?.evaluate("document.cookie") { v in
                self.check((v as? String)?.contains("drm=kept") == true, "\(tag): a WebKit page's cookie survives a relaunch (\(v as? String ?? "nil"))")
                done()
            }
        }
        // Clean up: the profile's WebKit store goes (as it does when the profile is deleted).
        var directory = ""
        run { [self] in
            directory = c.engineTab(for: id)?.profile.directory ?? ""
            c.closeTab(id)
        }
        wait(0.5)
        step { [self] done in
            engine.deleteWebKitData(directory: directory) { removed in
                engine.webKit.storeExists(directory: directory) { exists in
                    self.check(removed && !exists, "\(tag): the profile's WebKit store is deleted (removed \(removed), still there \(exists))")
                    done()
                }
            }
        }
    }
}
#endif
#endif
