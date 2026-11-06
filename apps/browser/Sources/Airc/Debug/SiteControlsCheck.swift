// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script sitecontrols` (both engines; SB-2): Site Controls on pages from a loopback server, through the URL field
/// and the panel, with real clicks and keys where a person would use them (SiteControls/).
///   - the slider button opens the panel under the field; Esc and a click outside close it;
///   - a permission set in the panel is what the page sees (navigator.permissions), at once; Reset Permissions;
///   - the camera indicator appears while the page uses the fake camera, opens the panel, and goes when it stops;
///   - a blocked pop-up shows its icon and is listed;
///   - zoom −/+ and reset, the same steps as ⌘+, for the whole site (Chromium) or the tab (WebKit);
///   - Clear site data (confirm, then reload) removes the page's cookie and localStorage entry;
///   - a Space with another profile shows that profile's settings (defaults);
///   - the panel in a light and a dark theme (sitecontrols-light.png, sitecontrols-dark.png).
/// Chromium's capture check needs fake devices without fake UI, and the engine's scratch-only system permission
/// override (`--use-fake-device-for-media-stream --airc-test=systemMediaPermission=granted` with `--airc-data-dir`),
/// so nothing real is captured and macOS never asks. The dev engine has no fake camera: there the check is skipped.
extension SnapshotRunner {
    func siteControlsScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let engine = { SiteControlsCenter.shared?.engine }
        let tag = chromium ? "chromium" : "webkit"
        var server: LocalPageServer?
        var base = ""
        var tabID = ""
        var homeSpace = ""
        let page = { self.c.engineTab(for: tabID) }
        let field = { self.c.pageView(for: self.c.currentSpaceID)?.urlField }
        let model = { self.c.siteControls?.model }
        let helpers = """
            <script>
            async function perm(n) { try { return (await navigator.permissions.query({name: n})).state } catch (e) { return 'error ' + e.name } }
            async function startCamera() {
              try { window.cam = await navigator.mediaDevices.getUserMedia({video: true}); return 'ok' } catch (e) { return e.name }
            }
            function stopCamera() { if (window.cam) { window.cam.getTracks().forEach(t => t.stop()); window.cam = null } return 'stopped' }
            function writeData() { document.cookie = 'sc=1; path=/; max-age=3600'; localStorage.setItem('sc', '1'); return document.cookie + '|' + localStorage.getItem('sc') }
            function readData() { return JSON.stringify({cookie: document.cookie, local: localStorage.getItem('sc')}) }
            </script>
            """

        step { [self] done in
            server = LocalPageServer(responses: [
                "/site": .init(body: "<title>site</title>\(helpers)<p>Site Controls test page</p>"),
                "/other": .init(body: "<title>other</title>\(helpers)<p>Another page of the same site</p>"),
                "/popup": .init(body: "<title>popup</title>\(helpers)<script>setTimeout(() => window.open('/other', '_blank'), 50)</script>"),
            ])
            guard let server else { check(false, "sitecontrols: the loopback server starts"); return done() }
            server.start { port in
                guard let port else { self.check(false, "sitecontrols: the loopback server starts"); return done() }
                base = "http://127.0.0.1:\(port)"
                done()
            }
        }

        func open(_ path: String, title: String) {
            run { [self] in
                guard !base.isEmpty, let t = try? c.store.openTab(url: base + path, inSpace: c.currentSpaceID, title: title) else { return }
                tabID = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            waitTitle(title)
        }
        func go(_ path: String, title: String) {
            run { if let url = URL(string: base + path) { page()?.load(url) } }
            waitTitle(title)
        }
        func waitTitle(_ title: String) {
            step { [self] done in
                waitUntil({ page()?.title == title && page()?.isLoading == false }, timeout: 10) {
                    if page()?.title != title { self.check(false, "sitecontrols: \(title) loads (\(page()?.title ?? "-"))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
            }
        }
        /// The page's answer to `js` (Chromium awaits a promise; the dev engine doesn't, so its checks stay synchronous).
        func js(_ code: String, _ then: @escaping (String) -> Void) {
            step { done in
                guard let p = page() else { then("no page"); return done() }
                p.evaluate(code) { value in
                    then(value.map { "\($0)" } ?? "nil")
                    done()
                }
            }
        }
        func expectJS(_ code: String, _ expected: String, _ what: String) {
            js(code) { [self] got in check(got == expected, "sitecontrols (\(tag)): \(what) (page says \(got))") }
        }
        func openPanel(_ how: String = "") {
            run { [self] in if c.siteControls == nil { c.toggleSiteControls() } }
            step { [self] done in
                waitUntil({ self.c.siteControls != nil }, timeout: 2) {
                    if !how.isEmpty { self.check(self.c.siteControls != nil, "sitecontrols (\(tag)): \(how)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                }
            }
        }
        func closePanel() { run { [self] in c.closeSiteControls(animated: false) } }
        /// A real click on an AppKit view (the field's buttons, its icons), through the window.
        func clickView(_ what: String, _ view: @escaping () -> NSView?) {
            step { [self] done in
                guard let v = view(), let w = v.window, !v.isHiddenOrHasHiddenAncestor else {
                    check(false, "sitecontrols (\(tag)): \(what) is on screen"); return done()
                }
                click(at: v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil), in: w, done)
            }
        }
        func clickPanel(_ anchor: String) {
            run { [self] in
                let p = c.siteControls
                note("sitecontrols: panel \(p.map { NSStringFromRect($0.frame) } ?? "closed"), card fits "
                     + "\(p.map { NSStringFromSize($0.hostingView.fittingSize) } ?? "-"), \(anchor) at "
                     + "\(TestAnchors.frames[anchor].map { NSStringFromRect($0) } ?? "-")")
            }
            clickIn({ self.c.siteControls?.hostingView }, anchor)
            run { [self] in note("sitecontrols: \(anchor): \(TestAnchors.lastHit[anchor] ?? "-"); panel \(c.siteControls == nil ? "closed" : "open")") }
        }
        func indicator(_ kind: SiteIndicatorsView.Kind) -> NSView? {
            field()?.siteIndicators.subviews.first { ($0 as? GlyphButton)?.toolTip == SiteIndicatorsView.help(kind) && !$0.isHidden }
        }
        func expectIndicator(_ kind: SiteIndicatorsView.Kind, _ shown: Bool, _ what: String, timeout: Double = 4) {
            step { [self] done in
                waitUntil({ (field()?.siteIndicators.kinds.contains(kind) ?? false) == shown }, timeout: timeout) {
                    let kinds = field()?.siteIndicators.kinds.map(\.rawValue).joined(separator: ",") ?? "-"
                    self.check((field()?.siteIndicators.kinds.contains(kind) ?? false) == shown, "sitecontrols (\(tag)): \(what) (icons: \(kinds))")
                    done()
                }
            }
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }

        open("/site", title: "site")
        run { [self] in homeSpace = c.currentSpaceID }

        // 1. The slider button opens it under the field; Esc closes it; a click outside closes it.
        run { [self] in c.sidebar.setHovered(true) }
        wait(0.3)
        clickView("the Site Controls button") {
            field()?.subviews.first { ($0 as? GlyphButton)?.toolTip == "Site Controls" }
        }
        step { [self] done in
            waitUntil({ self.c.siteControls != nil }, timeout: 2) {
                guard let p = self.c.siteControls, let f = field() else {
                    self.check(false, "sitecontrols (\(tag)): the slider button opens the panel"); return done()
                }
                let fieldBottom = self.c.root.convert(f.bounds, from: f).maxY
                self.check(abs(p.frame.minY - fieldBottom - PromptPresenter.gap) < 1.5,
                           String(format: "sitecontrols (\(tag)): the slider button opens the panel under the URL field (top %.0f, field bottom %.0f)", p.frame.minY, fieldBottom))
                let m = p.model
                self.check(m.host.hasPrefix("127.0.0.1") && m.security.level == .local && m.connectionText == "Local connection",
                           "sitecontrols (\(tag)): it names the site and its connection (\(m.host), \(m.connectionText))")
                done()
            }
        }
        run { [self] in c.sidebar.setHovered(false) }
        wait(0.4)
        key("\u{1b}", 53)
        step { [self] done in
            waitUntil({ self.c.siteControls == nil }, timeout: 2) {
                self.check(self.c.siteControls == nil, "sitecontrols (\(tag)): Esc closes it")
                done()
            }
        }
        openPanel()
        clickView("the page") { self.c.card }
        step { [self] done in
            waitUntil({ self.c.siteControls == nil }, timeout: 2) {
                self.check(self.c.siteControls == nil, "sitecontrols (\(tag)): a click outside closes it")
                done()
            }
        }

        // 2. Permissions: what the panel sets is what the page sees, at once; Reset Permissions.
        if chromium {
            expectJS("perm('camera')", "prompt", "camera starts at the default (ask)")
            openPanel()
            run { [self] in
                let ok = model()?.set(.camera, to: .allow) == true
                check(ok && model()?.permissions[.camera]?.state == .allow, "sitecontrols (\(tag)): the panel sets the camera to Allow")
                _ = model()?.set(.notifications, to: .block)
                _ = model()?.set(.clipboard, to: .allow)
                _ = model()?.set(.location, to: .allow)
                // The page's answer for location also needs macOS's own permission for the app, which a scripted run
                // never asks for: the engine's setting is what's checked.
                guard let p = page(), let o = SiteOrigin.of(p.url) else { return }
                let loc = engine()?.sitePermissions(for: o, in: p.profile)[.location]
                check(loc?.state == .allow && loc?.effective == .allow, "sitecontrols (\(tag)): the engine has location allowed for the site")
            }
            expectJS("perm('camera')", "granted", "the page sees the camera allowed")
            expectJS("perm('notifications')", "denied", "the page sees notifications blocked")
            expectJS("perm('clipboard-read')", "granted", "the page sees the clipboard allowed")
            expectIndicator(.custom, true, "the URL field shows the site's own settings")
            expectIndicator(.location, true, "the URL field shows the location arrow for an allowed site")
            clickPanel("site.reset")
            step { [self] done in
                waitUntil({ model()?.hasCustomPermissions == false }, timeout: 3) {
                    self.check(model()?.hasCustomPermissions == false, "sitecontrols (\(tag)): Reset Permissions (a real click) puts every one back to default")
                    done()
                }
            }
            expectJS("perm('camera')", "prompt", "after the reset the page is asked again for the camera")
            expectJS("perm('notifications')", "prompt", "after the reset notifications are back to ask")
            expectJS("perm('clipboard-read')", "prompt", "after the reset the clipboard is back to ask")
            expectIndicator(.custom, false, "the site-settings icon goes with the reset")
            expectIndicator(.location, false, "the location arrow goes with the reset")
            closePanel()
        } else {
            openPanel()
            run { [self] in
                check(model()?.permissionsAvailable == false && model()?.isWebsite == true,
                      "sitecontrols (\(tag)): the panel says permissions aren't available on the dev engine")
                skip("sitecontrols (\(tag)): permissions set/reset (WebKit keeps no per-site permissions; Chromium covers them)")
            }
            closePanel()
        }

        // 3. The camera indicator, live: appears while the fake camera is in use, opens the panel, goes when it stops.
        let args = CommandLine.arguments
        let fakeCamera = chromium && args.contains("--use-fake-device-for-media-stream") && !args.contains("--use-fake-ui-for-media-stream")
            && args.contains { $0.hasPrefix("--airc-test=") && $0.contains("systemMediaPermission=granted") }
        if fakeCamera {
            run { [self] in
                guard let p = page(), let o = SiteOrigin.of(p.url) else { return }
                SiteControlsCenter.shared?.set(.camera, to: .allow, origin: o, in: p.profile)
            }
            expectJS("startCamera()", "ok", "the page gets the fake camera")
            expectIndicator(.camera, true, "the camera icon shows in the URL field while the camera is in use", timeout: 8)
            clickView("the camera icon") { indicator(.camera) }
            step { [self] done in
                waitUntil({ self.c.siteControls != nil }, timeout: 2) {
                    let m = model()
                    self.check(m?.activity.camera == true && m?.usingText?.contains("camera") == true,
                               "sitecontrols (\(tag)): a click on the camera icon opens the panel, which says the camera is in use (\(m?.usingText ?? "-"))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
                }
            }
            captureSiteControls("sitecontrols-camera")
            expectJS("stopCamera()", "stopped", "the page stops the camera")
            expectIndicator(.camera, false, "the camera icon goes when the camera stops", timeout: 8)
            step { [self] done in
                waitUntil({ model()?.activity.camera == false }, timeout: 3) {
                    self.check(model()?.activity.camera == false, "sitecontrols (\(tag)): the open panel follows (camera no longer in use)")
                    done()
                }
            }
            run { [self] in model()?.resetPermissions() }
            closePanel()
        } else {
            run { [self] in
                skip("sitecontrols (\(tag)): camera indicator: " + (chromium ? "needs --use-fake-device-for-media-stream and --airc-test=systemMediaPermission=granted without fake UI"
                                                                          : "no fake camera on the dev engine (a real one would ask macOS)"))
            }
        }

        // 4. A blocked pop-up (Chromium's popup blocker): its icon, and the panel lists it.
        if chromium {
            go("/popup", title: "popup")
            expectIndicator(.popup, true, "a blocked pop-up shows its icon", timeout: 5)
            openPanel()
            run { [self] in
                let list = model()?.activity.blockedPopups ?? []
                check(list.count == 1 && list.first?.url.hasSuffix("/other") == true,
                      "sitecontrols (\(tag)): the panel lists the blocked pop-up (\(list.map(\.url)))")
            }
            closePanel()
            go("/site", title: "site")
            expectIndicator(.popup, false, "the pop-up icon goes with the next page")
        }

        // 5. Zoom: − / + / reset in the panel; the same steps as ⌘+; per site (Chromium) or per tab (WebKit).
        openPanel()
        run { [self] in check(model()?.zoomText == "100 %", "sitecontrols (\(tag)): zoom starts at 100 % (\(model()?.zoomText ?? "-"))") }
        clickPanel("site.zoomIn")
        step { [self] done in
            waitUntil({ near(page()?.zoomFactor ?? 0, 1.1) && near(model()?.zoom ?? 0, 1.1) }, timeout: 2) {
                self.check(near(page()?.zoomFactor ?? 0, 1.1) && model()?.zoomText == "110 %",
                           "sitecontrols (\(tag)): + (a real click) zooms the page to 110 % (page \(page()?.zoomFactor ?? 0), panel \(model()?.zoomText ?? "-"))")
                done()
            }
        }
        key("=", 24, .command)
        step { [self] done in
            waitUntil({ near(model()?.zoom ?? 0, 1.25) }, timeout: 2) {
                self.check(near(page()?.zoomFactor ?? 0, 1.25) && model()?.zoomText == "125 %",
                           "sitecontrols (\(tag)): ⌘+ takes the next step and the open panel follows (\(model()?.zoomText ?? "-"))")
                done()
            }
        }
        run { [self] in
            guard let p = page(), let o = SiteOrigin.of(p.url), let e = engine() else { return }
            if chromium {
                check(model()?.zoomScope == .site && model()?.zoomCaption == "This site" && near(e.siteZoomFactor(origin: o, in: p.profile) ?? 0, 1.25),
                      "sitecontrols (\(tag)): the zoom is the site's (\(model()?.zoomCaption ?? "-"))")
            } else {
                check(model()?.zoomScope == .tab && model()?.zoomCaption == "This tab", "sitecontrols (\(tag)): the zoom is the tab's (WebKit has no per-site zoom)")
            }
        }
        if chromium {
            closePanel()
            go("/other", title: "other")
            run { [self] in check(near(page()?.zoomFactor ?? 0, 1.25), "sitecontrols (\(tag)): another page of the site opens at the site's 125 % (\(page()?.zoomFactor ?? 0))") }
            go("/site", title: "site")
            openPanel()
        }
        clickPanel("site.zoomReset")
        step { [self] done in
            waitUntil({ near(page()?.zoomFactor ?? 0, 1) }, timeout: 2) {
                self.check(near(page()?.zoomFactor ?? 0, 1) && model()?.zoomText == "100 %",
                           "sitecontrols (\(tag)): reset (a real click) is back to 100 % (\(model()?.zoomText ?? "-"))")
                done()
            }
        }
        if chromium {
            run { [self] in
                guard let p = page(), let o = SiteOrigin.of(p.url) else { return }
                check(near(engine()?.siteZoomFactor(origin: o, in: p.profile) ?? 0, 1), "sitecontrols (\(tag)): …for the whole site")
            }
        }
        closePanel()

        // 6. Clear site data: counts, confirm, then the page reloads without its cookie and localStorage entry.
        expectJS("writeData()", "sc=1|1", "the page writes a cookie and a localStorage entry")
        openPanel()
        step { [self] done in
            waitUntil({ (model()?.data?.cookies ?? 0) >= 1 }, timeout: 5) {
                let d = model()?.data
                self.check((d?.cookies ?? 0) >= 1 && (d?.hasStorage == true || !chromium),
                           "sitecontrols (\(tag)): the panel counts the site's data (\(model()?.dataText ?? "-"))")
                done()
            }
        }
        // The document before the clear: the check reads the reloaded one, not this one.
        expectJS("window.__beforeClear = 1; 'marked'", "marked", "the page before the clear is marked")
        clickPanel("site.clear")
        step { [self] done in
            waitUntil({ model()?.confirmingClear == true }, timeout: 2) {
                self.check(model()?.confirmingClear == true, "sitecontrols (\(tag)): Clear… asks to confirm first")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
        }
        clickPanel("site.clearConfirm")
        step { [self] done in
            waitUntil({ self.c.siteControls == nil }, timeout: 8) {
                self.check(self.c.siteControls == nil, "sitecontrols (\(tag)): Clear Site Data clears, closes the panel and reloads")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
            }
        }
        step { [self] done in
            let deadline = Date().addingTimeInterval(8)
            func poll() {
                guard let p = page() else { return done() }
                p.evaluate("window.__beforeClear === 1 ? 'old' : 'new'") { value in
                    if "\(value ?? "")" == "new" || Date() > deadline {
                        self.check("\(value ?? "")" == "new", "sitecontrols (\(tag)): the page reloaded after the clear")
                        return done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
                }
            }
            poll()
        }
        waitTitle("site")
        js("readData()") { [self] got in
            let d = (got.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check(d != nil && (d?["cookie"] as? String) == "" && d?["local"] is NSNull,
                  "sitecontrols (\(tag)): after Clear the page has no cookie and no localStorage entry (\(got))")
        }

        // 7. Per profile: a Space with another profile shows that profile's settings.
        if chromium {
            run { [self] in
                guard let p = page(), let o = SiteOrigin.of(p.url) else { return }
                SiteControlsCenter.shared?.set(.camera, to: .allow, origin: o, in: p.profile)
                p.zoom(step: 1)
            }
        }
        expectJS("writeData()", "sc=1|1", "the first profile has data again")
        run { [self] in
            do {
                let first = c.store.selectedSpace
                let p = try c.profiles.createProfile(name: "Site Controls Test", emoji: "", color: nil)
                let s = try c.store.createSpace(name: "Other profile", icon: nil, theme: first.theme, profileID: p.id, after: first.id)
                c.switchToSpace(s.id, animated: false)
            } catch {
                check(false, "sitecontrols (\(tag)): a Space with another profile (\(error))")
            }
        }
        wait(0.5)
        open("/site", title: "site")
        openPanel()
        step { [self] done in
            waitUntil({ model()?.data != nil || model()?.dataAvailable == false }, timeout: 5) {
                let m = model()
                var ok = m?.profileName == "Site Controls Test" && (m?.data?.cookies ?? -1) == 0
                if chromium { ok = ok && m?.hasCustomPermissions == false && m?.permissions[.camera]?.state == .default && near(m?.zoom ?? 0, 1) }
                self.check(ok, "sitecontrols (\(tag)): the other profile's Space shows its own settings: default permissions, "
                           + "100 % and no data (\(m?.profileName ?? "-"), \(m?.zoomText ?? "-"), \(m?.dataText ?? "-"))")
                done()
            }
        }
        if chromium { expectJS("perm('camera')", "prompt", "the other profile's page isn't allowed the camera") }
        closePanel()
        run { [self] in c.switchToSpace(homeSpace, animated: false) }
        wait(0.5)
        run { [self] in
            if let t = c.store.lastActiveTab(ofSpace: homeSpace) { tabID = t.id; c.show(t.id, focus: false) }
        }
        wait(0.5)
        if chromium {
            openPanel()
            run { [self] in
                check(model()?.permissions[.camera]?.state == .allow && near(model()?.zoom ?? 0, 1.1),
                      "sitecontrols (\(tag)): back in the first Space its own settings are still there (\(model()?.zoomText ?? "-"))")
                model()?.zoom(step: 0)
                model()?.resetPermissions()
            }
            closePanel()
        }

        // 8. The panel in a light and a dark theme.
        for appearance in [Appearance.light, .dark] {
            run { [self] in
                try? c.store.updateSpace(homeSpace) { $0.theme.appearance = appearance }
                c.reloadAll(animated: false)
                if chromium, let p = page(), let o = SiteOrigin.of(p.url) {
                    SiteControlsCenter.shared?.set(.camera, to: .allow, origin: o, in: p.profile)
                    SiteControlsCenter.shared?.set(.notifications, to: .block, origin: o, in: p.profile)
                }
            }
            wait(0.4)
            openPanel()
            captureSiteControls("sitecontrols-\(appearance.rawValue)")
            closePanel()
        }
        run { [self] in
            if chromium, let p = page(), let o = SiteOrigin.of(p.url) { SiteControlsCenter.shared?.resetPermissions(origin: o, in: p.profile) }
            server?.stop()
        }
    }

    /// The window as `captureNow` draws it, with the panel drawn again over the page (which `captureNow` puts on top of
    /// everything that isn't one of its own overlays).
    func captureSiteControls(_ name: String) {
        step { [self] done in
            captureNow(name) { [self] in
                defer { done() }
                guard let panel = c.siteControls, let card = render(panel) else { return }
                let url = dir.appendingPathComponent(name + ".png")
                guard let window = NSImage(contentsOf: url) else { return }
                let size = c.root.bounds.size
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                window.draw(in: NSRect(origin: .zero, size: size))
                let f = panel.frame
                card.draw(in: NSRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
#endif
