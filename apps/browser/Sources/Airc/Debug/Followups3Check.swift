// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script followups3`: Site Controls and Safari's-engine (WebKit) pages, on loopback pages only. No account, no
/// camera, microphone or screen: the page script's geolocation answers with a made-up position (SiteUse.fake), macOS's
/// privacy answers are a test override (SystemPrivacy.overrides), and System Settings is never opened.
///   - both engines: the location in use (a read, held a moment; a watch until cleared; a navigation ends it) in the URL
///     field and Site Controls; macOS denying what a site may use (a permission row's note, a row of its own for screen
///     recording and on pages without permission rows), with the right System Settings pane;
///   - Chromium: the blocked pop-ups, each opened from the list, and "Always allow pop-ups for this site";
///   - Chromium's WebKit pages ("localhost" plays a listed service: AIRC_WEBKIT_HOSTS): a Boost's style end to end, the
///     extension buttons dimmed with "Extensions don't run on …" (an unpacked test extension; needs the engine's test
///     gate), a Little Arc link handing off in place, unloading after the timeout (back with history and scroll, kept
///     while media plays), and picture in picture on leaving the tab (the request needs a key window: FAIL-ENV without).
extension SnapshotRunner {
    func followups3Scenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = "followups3 (\(chromium ? "chromium" : "webkit"))"
        var server: LocalPageServer?
        var port: UInt16 = 0
        let other = { (path: String) in "http://127.0.0.1:\(port)\(path)" }
        let listed = { (path: String) in "http://localhost:\(port)\(path)" }
        var tabID = ""
        let page = { self.c.engineTab(for: tabID) }
        let model = { self.c.siteControls?.model }
        let field = { self.c.pageView(for: self.c.currentSpaceID)?.urlField }
        let indicators = { field()?.siteIndicators.kinds ?? [] }

        let geo = """
            <title>geo</title><p>Location test page</p>
            <script>
            function once() { navigator.geolocation.getCurrentPosition(function (p) { window.__read = p.coords.latitude; }); return 'asked'; }
            function watchOn() { window.__w = navigator.geolocation.watchPosition(function () { window.__ticks = (window.__ticks || 0) + 1; }); return 'watching'; }
            function watchOff() { navigator.geolocation.clearWatch(window.__w); return 'cleared'; }
            </script>
            """
        let video = """
            <title>video</title><p>Video test page</p>
            <script>
            // A canvas stream (no file, no device), muted, playing.
            function play() { var c = document.createElement('canvas'); c.width = 160; c.height = 90; var g = c.getContext('2d'), n = 0;
              setInterval(function(){ g.fillStyle = 'hsl(' + (n++ * 9 % 360) + ',60%,50%)'; g.fillRect(0, 0, 160, 90); }, 100);
              var v = document.createElement('video'); v.muted = true; v.playsInline = true; v.srcObject = c.captureStream(10);
              v.style.width = '320px'; document.body.appendChild(v); window.__v = v; v.play(); return 'playing'; }
            </script>
            """
        let long = "<title>long</title><div style=\"height:6000px;background:linear-gradient(#fff,#ccd)\">Long page</div>"
        let boost = """
            <!doctype html><html><head><title>boost</title>
            <script>(function () { window.__atStart = getComputedStyle(document.documentElement).filter; })();</script>
            <style>body { font-family: Times } #hero { color: rgb(10, 20, 30) }</style></head>
            <body><h1 id="hero">Boost on a WebKit page</h1>
            <script>window.__heroAtParse = getComputedStyle(document.getElementById('hero')).color;</script></body></html>
            """
        let little = """
            <title>little</title>
            <p><a id="in" style="display:block;width:220px;height:30px">to the service</a></p>
            <script>document.getElementById('in').href = location.protocol + '//localhost:' + location.port + '/service?from=little';</script>
            """

        step { [self] done in
            if chromium { ProtectedMedia.shared.testHosts = ["localhost"] }
            server = LocalPageServer(responses: [
                "/geo": .init(body: geo),
                "/geo2": .init(body: geo.replacingOccurrences(of: "<title>geo</title>", with: "<title>geo2</title>")),
                "/popups": .init(body: "<title>popups</title><script>setTimeout(function () { window.open('/pa', '_blank'); window.open('/pb', '_blank'); }, 50)</script>"),
                "/pa": .init(body: "<title>pa</title><p>pop-up a</p>"),
                "/pb": .init(body: "<title>pb</title><p>pop-up b</p>"),
                "/service": .init(body: "<title>service</title><p>a listed service</p>"),
                "/video": .init(body: video),
                "/long": .init(body: long),
                "/boost": .init(body: boost),
                "/little": .init(body: little),
            ])
            guard let server else { check(false, "\(tag): the loopback server starts"); return done() }
            server.start { p in port = p ?? 0; done() }
        }

        func open(_ url: @escaping @autoclosure () -> String, title: String, _ set: ((String) -> Void)? = nil) {
            run { [self] in
                guard port != 0, let t = try? c.store.openTab(url: url(), inSpace: c.currentSpaceID) else { return check(false, "\(tag): a tab for \(url())") }
                tabID = t.id
                set?(t.id)
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            waitTitle(title)
        }
        func waitTitle(_ title: String, of id: (() -> String)? = nil) {
            step { [self] done in
                let p = { id.map { self.c.engineTab(for: $0()) } ?? page() }
                waitUntil({ p()?.title == title && p()?.isLoading == false }, timeout: 10) {
                    if p()?.title != title { self.check(false, "\(tag): \(title) loads (\(p()?.title ?? "-"))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
            }
        }
        /// Runs `code` in the page's main world (where the page script's wrappers are): DevTools on Chromium pages (the
        /// app's evaluate is another world there), the page world on WebKit pages.
        func main(_ code: String, in p: (() -> EngineTab?)? = nil, _ then: @escaping (Any?) -> Void) {
            guard let tab = (p ?? page)() else { return then(nil) }
            #if canImport(AircCore)
            if let engine = app?.engine as? ChromiumEngine, !(tab is WebKitTab) {
                engine.devToolsCall("Runtime.evaluate", params: ["expression": code, "returnByValue": true, "userGesture": true], in: tab) { r, _ in
                    then((r?["result"] as? [String: Any])?["value"])
                }
                return
            }
            #endif
            tab.evaluate(code, completion: then)
        }
        func mainStep(_ code: String) { step { done in main(code) { _ in done() } } }
        func expect(_ what: String, timeout: Double = 4, _ ok: @escaping () -> Bool, _ detail: @escaping () -> String = { "" }) {
            step { [self] done in
                waitUntil(ok, timeout: timeout) {
                    let d = detail()
                    self.check(ok(), "\(tag): \(what)" + (d.isEmpty ? "" : " (\(d))"))
                    done()
                }
            }
        }
        func showPanel() {
            run { [self] in c.closeSiteControls(animated: false); c.showSiteControls() }
            wait(0.5)
        }
        func closePanel() { run { [self] in c.closeSiteControls(animated: false) } }
        let using = { self.c.siteControls == nil ? "no panel" : (model()?.usingText ?? "nothing in use") }

        // 1. The location in use: the page script's geolocation (a made-up position here) shows live.
        open(other("/geo"), title: "geo")
        run { [self] in
            check(SiteUse.fake, "\(tag): the page script answers geolocation with a made-up position (no CoreLocation, no prompt)")
            SiteUse.readHold = 2
        }
        expect("no location arrow before the page reads the location", { !indicators().contains(.location) }) { "\(indicators())" }
        mainStep("once()")
        expect("a one-shot read shows the location arrow in the URL field", { indicators().contains(.location) }) { "\(indicators())" }
        run { [self] in
            let tint = field()?.siteIndicators.subviews.compactMap { $0 as? GlyphButton }.first { $0.toolTip == SiteIndicatorsView.help(.location) }?.tint
            check(tint == NSColor.systemBlue, "\(tag): the arrow is blue while in use, with its tooltip (\(tint.map { "\($0)" } ?? "no button"))")
        }
        showPanel()
        run { [self] in
            check(model()?.activity.location == true && model()?.usingText?.contains("your location") == true,
                  "\(tag): Site Controls says the page is using the location (\(using()))")
        }
        capture("followups3-location")
        closePanel()
        expect("the arrow goes a moment after a one-shot read", timeout: 5, { !indicators().contains(.location) }) { "\(indicators())" }
        mainStep("watchOn()")
        expect("a watch shows the location arrow", { indicators().contains(.location) }) { "\(indicators())" }
        wait(3)   // longer than a read's hold
        run { [self] in check(indicators().contains(.location), "\(tag): the arrow stays while the watch runs (\(indicators()))") }
        mainStep("watchOff()")
        expect("clearing the watch takes the arrow away", { !indicators().contains(.location) }) { "\(indicators())" }
        mainStep("watchOn()")
        expect("a second watch shows the arrow again", { indicators().contains(.location) })
        run { [self] in page()?.load(URL(string: other("/geo2"))!) }
        waitTitle("geo2")
        expect("leaving the page ends its location use", { !indicators().contains(.location) }) { "\(indicators())" }
        run { SiteUse.readHold = 15 }

        // 2. macOS denies what the site may use (a test override of the authorization status, never a prompt).
        run { [self] in
            SystemPrivacy.overrides = [.camera: .denied, .microphone: .granted, .location: .restricted, .screen: .denied]
            SystemPrivacy.opened = []
            guard chromium, let p = page(), let o = SiteOrigin.of(p.url) else { return }
            SiteControlsCenter.shared?.set(.camera, to: .allow, origin: o, in: p.profile)
            SiteControlsCenter.shared?.set(.microphone, to: .allow, origin: o, in: p.profile)
        }
        mainStep("once()")   // asks for the location (the dev engine has no saved permissions: the ask is what counts)
        wait(0.3)
        showPanel()
        run { [self] in
            let m = model()
            if chromium {
                check(m?.systemBlocked == [.camera, .location] && m?.systemBlocks(.camera) == true && m?.systemBlocks(.microphone) == false,
                      "\(tag): an allowed camera and an asked-for location that macOS denies are said in their rows (\(m?.systemBlocked.map(\.rawValue) ?? []))")
                check(m?.systemRows.isEmpty == true && TestAnchors.frames["site.system.camera"] != nil && TestAnchors.frames["site.system.location"] != nil,
                      "\(tag): the Camera and Location rows say \"Off in macOS\" (rows of their own \(m?.systemRows.map(\.rawValue) ?? []))")
            } else {
                check(m?.systemBlocked == [.location] && m?.systemRows == [.location] && TestAnchors.frames["site.system.location"] != nil,
                      "\(tag): without permission rows, the asked-for location that macOS denies gets a row of its own (\(m?.systemRows.map(\.rawValue) ?? []))")
            }
        }
        // A site that asked to share the screen (as if: no getDisplayMedia in tests) while macOS denies screen recording.
        run { [self] in if let p = page() { SiteUse.shared.noteAsk(.screen, in: p) } }
        wait(0.4)
        run { [self] in
            check(model()?.systemRows.contains(.screen) == true && TestAnchors.frames["site.system.screen"] != nil,
                  "\(tag): screen recording off in macOS gets its own row for a site that asked (\(model()?.systemRows.map(\.rawValue) ?? []))")
        }
        capture("followups3-macos")
        run { [self] in
            model()?.openSystemSettings(.screen)
            model()?.openSystemSettings(chromium ? .camera : .location)
            let urls = SystemPrivacy.opened.map(\.absoluteString)
            check(urls == ["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                           "x-apple.systempreferences:com.apple.preference.security?Privacy_" + (chromium ? "Camera" : "LocationServices")],
                  "\(tag): Open Settings goes to the right Privacy & Security pane, and a scripted run never opens it (\(urls))")
            SystemPrivacy.overrides = [.camera: .granted, .microphone: .granted, .location: .granted, .screen: .granted]
            model()?.reloadSystem()
            check(model()?.systemBlocked.isEmpty == true, "\(tag): once macOS allows them, the notes go (\(model()?.systemBlocked.map(\.rawValue) ?? []))")
            SystemPrivacy.overrides = [:]
            // The real state, read only (these calls never prompt): for the record.
            note("\(tag): macOS says camera \(SystemPrivacy.status(.camera).rawValue), microphone \(SystemPrivacy.status(.microphone).rawValue), "
                 + "location \(SystemPrivacy.status(.location).rawValue), screen \(SystemPrivacy.status(.screen).rawValue)")
            if chromium, let p = page(), let o = SiteOrigin.of(p.url) { SiteControlsCenter.shared?.resetPermissions(origin: o, in: p.profile) }
        }
        closePanel()

        guard chromium else {
            run { [self] in skip("\(tag): pop-ups and Safari's-engine pages are Chromium's (the dev engine reports no blocked pop-ups)") }
            run { server?.stop() }
            return
        }
        #if canImport(AircCore)
        followups3Chromium(tag: tag, other: other, listed: listed, open: { url, title, set in open(url(), title: title, set) },
                           waitTitle: waitTitle, main: main, expect: expect, showPanel: showPanel, closePanel: closePanel,
                           page: page, setTab: { tabID = $0 }, tabID: { tabID })
        #endif
        run { server?.stop() }
    }

    #if canImport(AircCore)
    // swiftlint:disable:next function_parameter_count
    private func followups3Chromium(tag: String, other: @escaping (String) -> String, listed: @escaping (String) -> String,
                                    open: @escaping (@escaping () -> String, String, ((String) -> Void)?) -> Void,
                                    waitTitle: @escaping (String, (() -> String)?) -> Void,
                                    main: @escaping (String, (() -> EngineTab?)?, @escaping (Any?) -> Void) -> Void,
                                    expect: @escaping (String, Double, @escaping () -> Bool, @escaping () -> String) -> Void,
                                    showPanel: @escaping () -> Void, closePanel: @escaping () -> Void,
                                    page: @escaping () -> EngineTab?, setTab: @escaping (String) -> Void, tabID: @escaping () -> String) {
        guard let engine = app?.engine as? ChromiumEngine else { return }
        let model = { self.c.siteControls?.model }
        let field = { self.c.pageView(for: self.c.currentSpaceID)?.urlField }
        func isWebKit(_ id: String) -> Bool { ProtectedMedia.isWebKitPage(c.engineTab(for: id)) }
        func todayIDs() -> Set<String> { Set(c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id)) }
        func eval(_ code: String, _ then: @escaping (Any?) -> Void) {
            guard let p = page() else { return then(nil) }
            p.evaluate(code, completion: then)
        }

        // 3. Blocked pop-ups: the list, Open per entry, and "Always allow pop-ups for this site".
        var popupsTab = ""
        var before = Set<String>()
        run { before = todayIDs() }
        open({ other("/popups") }, "popups") { popupsTab = $0 }
        expect("the engine blocks both pop-ups of the page", 5, { page().flatMap { p in SiteControlsCenter.shared?.activity(of: p) }?.blockedPopups.count == 2 }) {
            "\(page().flatMap { p in SiteControlsCenter.shared?.activity(of: p).blockedPopups.map(\.url) } ?? [])"
        }
        expect("the pop-up icon shows in the URL field", 3, { field()?.siteIndicators.kinds.contains(.popup) == true }) { "" }
        showPanel()
        run { [self] in
            let list = model()?.activity.blockedPopups ?? []
            check(list.count == 2 && list.first?.url.hasSuffix("/pa") == true && list.last?.url.hasSuffix("/pb") == true
                  && TestAnchors.frames["site.popupsTitle"] != nil && TestAnchors.frames["site.popupsAllow"] != nil,
                  "\(tag): Site Controls lists the blocked pop-ups with \"Always allow pop-ups for this site\" (\(list.map(\.url)))")
        }
        capture("followups3-popups")
        run { [self] in
            guard let first = model()?.activity.blockedPopups.first else { return }
            model()?.openPopup(first, always: false)
        }
        expect("Open on an entry opens that pop-up as a tab", 6, { [self] in
            c.store.todayTabs(ofSpace: c.currentSpaceID).contains { !before.contains($0.id) && $0.url.hasSuffix("/pa") }
        }) { "" }
        run { [self] in
            if c.shownTabID != popupsTab { c.show(popupsTab, focus: false) }
        }
        wait(0.3)
        showPanel()
        run { [self] in
            let list = model()?.activity.blockedPopups ?? []
            check(list.count == 1 && list.first?.url.hasSuffix("/pb") == true, "\(tag): the opened one leaves the list (\(list.map(\.url)))")
            model()?.allowPopups()
            check(model()?.popupsAllowed == true && model()?.permissions[.popups]?.state == .allow,
                  "\(tag): \"Always allow pop-ups for this site\" allows them (\(model()?.permissions[.popups]?.state.rawValue ?? "-"))")
        }
        closePanel()
        run { [self] in
            for t in c.store.todayTabs(ofSpace: c.currentSpaceID) where !before.contains(t.id) && t.id != popupsTab { c.closeTab(t.id) }
            before = todayIDs()
            page()?.reload()
        }
        expect("with pop-ups allowed, the page's two pop-ups open as tabs", 8, { [self] in
            c.store.todayTabs(ofSpace: c.currentSpaceID).filter { !before.contains($0.id) }.count == 2
        }) { [self] in "\(c.store.todayTabs(ofSpace: c.currentSpaceID).filter { !before.contains($0.id) }.map(\.url))" }
        run { [self] in
            for t in c.store.todayTabs(ofSpace: c.currentSpaceID) where !before.contains(t.id) { c.closeTab(t.id) }
            if let p = c.engineTab(for: popupsTab), let o = SiteOrigin.of(p.url) { SiteControlsCenter.shared?.resetPermissions(origin: o, in: p.profile) }
            c.closeTab(popupsTab)
        }

        // 8. A Boost's style on a WebKit page, end to end: at document start, live, and its URL-field brush.
        var boosted = ""
        run { BoostCenter.shared?.update(domain: "localhost") {
            $0.colors = BoostColors(hue: 0.58, tint: 0, brightness: 0.9, contrast: 1, invert: true)
            $0.css = "#hero { color: rgb(1, 2, 3) !important; }"
        } }
        wait(0.6)   // the engine gets the new page script a moment later
        open({ listed("/boost") }, "boost") { boosted = $0 }
        step { [self] done in
            eval("JSON.stringify([window.__atStart, window.__heroAtParse])") { v in
                let got = v as? String ?? "nil"
                self.check(isWebKit(boosted) && got.contains("invert(1)") && got.contains("rgb(1, 2, 3)"),
                           "\(tag): a Boost's colours and CSS apply on a WebKit page from its first script (\(isWebKit(boosted) ? "WebKit" : "Chromium") \(got))")
                done()
            }
        }
        expect("the URL field shows the Boost's brush on the WebKit page", 3, { field()?.siteIndicators.kinds.contains(.boost) == true }) { "" }
        run { [self] in
            eval("window.__kept = 'same page'; 1") { _ in }
            BoostCenter.shared?.update(domain: "localhost") { $0.colors.invert = false; $0.css = "#hero { color: rgb(4, 5, 6) !important; }" }
        }
        step { [self] done in
            func poll(_ left: Int) {
                eval("[getComputedStyle(document.documentElement).filter, getComputedStyle(document.getElementById('hero')).color, window.__kept].join('|')") { v in
                    let got = v as? String ?? "nil"
                    if (!got.contains("invert") && got.contains("rgb(4, 5, 6)") && got.hasSuffix("|same page")) || left == 0 {
                        self.check(!got.contains("invert") && got.contains("rgb(4, 5, 6)") && got.hasSuffix("|same page"),
                                   "\(tag): an edit applies to the open WebKit page at once, without a reload (\(got))")
                        return done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll(left - 1) }
                }
            }
            poll(20)
        }
        run { [self] in BoostCenter.shared?.setEnabled(false, domain: "localhost", page: page()) }
        step { [self] done in
            func poll(_ left: Int) {
                eval("getComputedStyle(document.getElementById('hero')).color") { v in
                    let got = v as? String ?? "nil"
                    if got == "rgb(10, 20, 30)" || left == 0 {
                        self.check(got == "rgb(10, 20, 30)", "\(tag): switching the Boost off puts the WebKit page back (\(got))")
                        return done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll(left - 1) }
                }
            }
            poll(25)
        }
        run { [self] in BoostCenter.shared?.remove(domain: "localhost", page: page()) }

        // 5. Extension buttons on a WebKit page: dimmed, "Extensions don't run on …", and the puzzle list says so.
        var extensionID: String?
        let gate = Self.engineTestGateOpens
        step { [self] done in
            guard gate, let profile = page()?.profile as? ChromiumProfile else {
                skip("\(tag): extension buttons (the unpacked test extension needs the engine's test gate: --airc-data-dir)")
                return done()
            }
            let folder = dir.appendingPathComponent("followups3-extension", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = #"{"manifest_version": 3, "name": "Airc test", "version": "1", "action": {"default_title": "Airc test action"}}"#
            try? manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            profile.core.loadUnpackedExtension(forTesting: folder.path) { id, error in
                DispatchQueue.main.async {
                    extensionID = id
                    if let error { self.note("\(tag): the test extension: \(error)") }
                    if let id { self.c.setExtension(id, pinned: true) }
                    done()
                }
            }
        }
        func buttons() -> [ExtensionButton] { field()?.subviews.compactMap { $0 as? ExtensionButton } ?? [] }
        func extensionCheck(webKit: Bool) {
            step { [self] done in
                guard let id = extensionID else { return done() }
                waitUntil({ self.c.extensionActions().contains { $0.id == id } }, timeout: 5) {
                    self.c.refreshExtensionButtons()
                    let b = buttons().first { $0.id == id }
                    let a = self.c.extensionActions().first { $0.id == id }
                    if webKit {
                        self.check(b?.alphaValue == 0.4 && b?.toolTip == "Extensions don't run on localhost" && a?.isActive == false,
                                   "\(tag): on a WebKit page the pinned extension is dimmed, its tooltip \"\(b?.toolTip ?? "-")\" (alpha \(b?.alphaValue ?? -1))")
                        self.check(self.c.extensionsListNote() == "Extensions don't run on localhost: it plays with Safari's engine.",
                                   "\(tag): the puzzle list says so too (\(self.c.extensionsListNote() ?? "nothing"))")
                        let ran = field().map { f in self.c.runExtension(id, anchor: f, rect: f.extensionAnchor(for: id)) } ?? true
                        self.check(!ran, "\(tag): a click on it there opens nothing and says why")
                    } else {
                        self.check(b?.alphaValue == 1 && b?.toolTip == "Airc test action" && self.c.extensionsListNote() == nil,
                                   "\(tag): on a Chromium page it is back to normal (alpha \(b?.alphaValue ?? -1), \"\(b?.toolTip ?? "-")\")")
                    }
                    done()
                }
            }
        }
        var service = ""
        open({ listed("/service") }, "service") { service = $0 }
        extensionCheck(webKit: true)
        run { [self] in field()?.sidebarHovered = true }
        wait(0.3)
        capture("followups3-extensions")
        run { [self] in field()?.sidebarHovered = false }
        open({ other("/geo") }, "geo", nil)
        extensionCheck(webKit: false)

        // 6. A link inside Little Arc to a listed service hands off to WebKit in place.
        var littleArc: LittleArcController?
        var littleOld: EngineTab?
        run { [self] in littleArc = app?.openLittleArc(url: URL(string: other("/little"))) }
        step { [self] done in waitUntil({ littleArc?.page?.title == "little" && littleArc?.page?.isLoading == false }, timeout: 8) { done() } }
        step { [self] done in
            littleOld = littleArc?.page
            check(littleOld != nil && !ProtectedMedia.isWebKitPage(littleOld), "\(tag): Little Arc opens another site in Chromium")
            guard let p = littleOld else { return done() }
            engine.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('in').click(); true", "userGesture": true], in: p) { _, _ in done() }
        }
        step { [self] done in
            waitUntil({ ProtectedMedia.isWebKitPage(littleArc?.page) && littleArc?.page?.url?.query == "from=little" }, timeout: 8) {
                let p = littleArc?.page
                self.check(ProtectedMedia.isWebKitPage(p) && littleOld?.isClosed == true && littleArc?.window.isVisible == true
                           && p?.view.isDescendant(of: littleArc!.engineWindow.hostView) == true,
                           "\(tag): a Little Arc page's link to a listed site opens again in WebKit, in the same window (\(ProtectedMedia.isWebKitPage(p) ? "WebKit" : "Chromium"), old page closed \(littleOld?.isClosed ?? false), \(p?.url?.absoluteString ?? "-"))")
                done()
            }
        }
        captureLittleArc({ littleArc }, "followups3-littlearc")
        run { littleArc?.closeWindow() }
        step { [self] done in waitUntil({ littleArc?.window.isVisible == false }, timeout: 5) { done() } }

        // 7. Unloading: a hidden WebKit page closes after the timeout and comes back with its history and scroll; one
        //    playing a video stays until it stops.
        var sleeper = "", player = ""
        run { [self] in
            WindowController.unloadOverride = 2
            // Leaving the video's tab would put it in picture in picture (section 4), which keeps the page.
            app?.settings.values.pipAutomatic = false
            c.applyPictureInPictureSettings()
        }
        open({ listed("/long?first") }, "long") { sleeper = $0 }
        run { page()?.load(URL(string: listed("/long?second"))!) }
        step { [self] done in waitUntil({ page()?.url?.query == "second" && page()?.isLoading == false }, timeout: 8) { done() } }
        step { done in eval("window.scrollTo(0, 1500); window.scrollY") { _ in done() } }
        wait(0.4)
        open({ listed("/video") }, "video") { player = $0 }
        step { done in eval("play()") { _ in done() } }
        wait(0.8)
        open({ other("/geo") }, "geo", nil)
        expect("a hidden WebKit page unloads after the inactive-tab timeout, and its tab stays", 8, { [self] in
            c.engineTab(for: sleeper) == nil && c.store.tab(sleeper) != nil && c.isPageUnloaded(sleeper)
        }) { [self] in "page \(c.engineTab(for: sleeper) == nil ? "closed" : "still loaded"), tab \(c.store.tab(sleeper) != nil)" }
        run { [self] in
            check(c.engineTab(for: player) != nil, "\(tag): a hidden WebKit page playing a video stays loaded (\(c.engineTab(for: player) != nil))")
        }
        run { [self] in c.engineTab(for: player)?.evaluate("window.__v && window.__v.pause(); true", completion: nil) }
        expect("once the video stops, that page unloads too", 8, { [self] in c.engineTab(for: player) == nil }) { "" }
        run { [self] in setTab(sleeper); c.show(sleeper, focus: false) }
        step { [self] done in waitUntil({ page()?.url?.query == "second" && page()?.isLoading == false }, timeout: 8) { done() } }
        wait(0.5)
        step { [self] done in
            eval("window.scrollY") { y in
                let y = (y as? NSNumber)?.doubleValue ?? -1
                self.check(isWebKit(sleeper) && y > 1000 && page()?.canGoBack == true,
                           "\(tag): shown again, it is WebKit with its scroll position and history (scrollY \(Int(y)), back \(page()?.canGoBack ?? false))")
                done()
            }
        }
        run { [self] in
            WindowController.unloadOverride = nil
            c.closeTab(sleeper)
            c.closeTab(player)
        }

        // 4. Picture in picture on leaving a WebKit tab with a playing video.
        var pip = ""
        run { [self] in
            app?.settings.values.pipAutomatic = true
            c.applyPictureInPictureSettings()
            HybridTesting.autoPictureInPicture = []
        }
        open({ listed("/video?pip") }, "video") { pip = $0 }
        step { done in eval("play()") { _ in done() } }
        wait(1)
        open({ other("/geo") }, "geo", nil)
        wait(0.3)
        run { [self] in
            let key = c.window.isKeyWindow
            let got = c.engineTab(for: pip).flatMap { p in HybridTesting.autoPictureInPicture.last { $0.page == ObjectIdentifier(p) } }?.result
            check(got == (key ? "requested" : "the window isn't key"),
                  "\(tag): leaving the WebKit tab asks for picture in picture in the key window (window key \(key): \(got ?? "nothing asked"))")
        }
        // A site set to never: not asked.
        run { [self] in
            guard let origin = c.engineTab(for: pip)?.url.flatMap({ WindowController.pictureInPictureOrigin($0.absoluteString) }) else { return }
            app?.settings.values.pipSites[origin] = false
            c.show(pip, focus: false)
        }
        wait(0.3)
        open({ other("/geo2") }, "geo2", nil)
        run { [self] in
            let got = c.engineTab(for: pip).flatMap { p in HybridTesting.autoPictureInPicture.last { $0.page == ObjectIdentifier(p) } }?.result
            check(got == "off for this site", "\(tag): a site set to never isn't asked (\(got ?? "-"))")
            if let origin = c.engineTab(for: pip)?.url.flatMap({ WindowController.pictureInPictureOrigin($0.absoluteString) }) {
                app?.settings.values.pipSites[origin] = nil
            }
            c.show(pip, focus: false)
        }
        wait(0.4)
        // The request itself: WebKit's picture in picture opens (it may want a key window; then FAIL-ENV).
        step { [self] done in
            guard let p = c.engineTab(for: pip) as? WebKitTab else { return done() }
            ChromiumWindow.requestPictureInPicture(p) { asked in
                self.waitUntil({ false }, timeout: 1.5) {
                    p.evaluate("document.pictureInPictureElement ? 'in' : 'out'") { v in
                        let inPiP = v as? String == "in"
                        let what = "\(tag): the WebKit page's video enters the system picture in picture (asked: \(asked), now \(v as? String ?? "?"))"
                        if !inPiP && !self.c.window.isKeyWindow { self.note("FAIL-ENV " + what + " (our window isn't key: the scripted run never takes focus)") }
                        else { self.check(inPiP, what) }
                        p.evaluate("document.pictureInPictureElement && document.exitPictureInPicture(); window.__v && window.__v.pause(); true", completion: nil)
                        done()
                    }
                }
            }
        }
        wait(0.6)
        run { [self] in
            c.closeTab(pip)
            if !service.isEmpty { c.closeTab(service) }
            if let id = extensionID { c.setExtension(id, pinned: false) }
            _ = tabID
        }
    }
    #endif
}
#endif
