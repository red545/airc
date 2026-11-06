// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script private` (both engines; PW-1): private windows on loopback pages.
///   - ⇧⌘N opens a dark private window; its page loads there, not in the main window;
///   - the page leaves nothing behind: no row in Airc's history or Chromium's, no tab in the store (session restore)
///     or the Archive, nothing for ⌘T in the main window; the private Command Bar shows no history either;
///   - the main window's cookies aren't visible in it, and its own cookie isn't visible in the main window;
///   - ⌘T in it opens a tab in it, ⌘W closes one, ⇧⌘N opens another private window, which shares the session;
///   - after the last private window closes, a new one starts with no cookie of the old session;
///   - Chromium: a DRM service's page (loopback, chosen for Safari's engine) plays in WebKit in a private store of its
///     own, without the main profile's WebKit cookies;
///   - the window as drawn (private-window.png).
/// Keys are posted to the app's queue for the private window, never as HID input.
extension SnapshotRunner {
    func privateWindowScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        var server: LocalPageServer?
        var port: UInt16 = 0
        let token = "pwtok\(Int.random(in: 100_000...999_999))"
        let mainToken = "maintok\(Int.random(in: 100_000...999_999))"
        var mainTabID = ""
        var first: PrivateWindowController?
        var second: PrivateWindowController?
        var third: PrivateWindowController?
        let browsing = PrivateBrowsing.shared
        func base(_ host: String = "127.0.0.1") -> String { "http://\(host):\(port)" }
        let page = { (title: String) in "<!doctype html><html><head><title>\(title)</title></head><body><h1>\(title)</h1></body></html>" }

        step { [self] done in
            server = LocalPageServer(responses: [
                "/main": .init(headers: ["Set-Cookie": "main=1; Path=/"], body: page("main page")),
                "/p1": .init(headers: ["Set-Cookie": "pw=1; Path=/"], body: page("private one")),
                "/p2": .init(body: page("private two")),
                "/read": .init(body: page("reader")),
            ])
            guard let server else { check(false, "private: the loopback server starts"); return done() }
            server.start { p in
                if let p { port = p } else { self.check(false, "private: the loopback server starts") }
                done()
            }
        }

        // The main window's page, with its cookie (and, as a control, its history).
        run { [self] in
            guard port != 0, let t = try? c.store.openTab(url: base() + "/main?" + mainToken, inSpace: c.currentSpaceID, title: "main") else { return }
            mainTabID = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        waitPage({ self.c.engineTab(for: mainTabID) }, title: "main page", "private (\(tag)): the main window's page loads")
        cookie({ self.c.engineTab(for: mainTabID) }) { [self] v in check(v.contains("main=1"), "private (\(tag)): the main window's page has its cookie (\(v))") }

        // ⇧⌘N from the main window's menu command.
        step { [self] done in
            guard let app else { return done() }
            browsing.open(app: app) { w in
                first = w
                done()
            }
        }
        run { [self] in
            guard let w = first else { return check(false, "private (\(tag)): ⇧⌘N opens a private window") }
            check(browsing.windows.count == 1 && w.window.isVisible, "private (\(tag)): ⇧⌘N opens a private window (\(browsing.windows.count) open)")
            check(w.palette.isDark && w.window.appearance?.name == .darkAqua, "private (\(tag)): the private window is dark")
            check(w.sidebar.badge.isHidden == false && w.pages.isEmpty, "private (\(tag)): it shows the Private row and no tabs yet")
            w.openPage(URL(string: base() + "/p1?" + token))
        }
        waitPage({ first?.shownPage }, title: "private one", "private (\(tag)): a private window loads a page")
        run { [self] in
            check(c.engineTab(for: mainTabID)?.title == "main page" && c.store.state.tabs.values.allSatisfy { !$0.url.contains(token) },
                  "private (\(tag)): the page opened in the private window, not the main one")
        }
        cookie({ first?.shownPage }) { [self] v in
            check(!v.contains("main=1"), "private (\(tag)): the main window's cookie isn't visible in the private window (\(v.isEmpty ? "none" : v))")
            check(v.contains("pw=1"), "private (\(tag)): the private page keeps its own cookie while open (\(v))")
        }
        run { [self] in c.engineTab(for: mainTabID)?.load(URL(string: base() + "/read?main")!) }
        waitPage({ self.c.engineTab(for: mainTabID) }, title: "reader", "private (\(tag)): the main window reads its cookies")
        cookie({ self.c.engineTab(for: mainTabID) }) { [self] v in check(!v.contains("pw=1"), "private (\(tag)): the private cookie isn't visible in the main window (\(v))") }

        // Nothing kept: Airc's history, the store (session restore and the Archive), Chromium's history, ⌘T.
        wait(1.5)
        step { [self] done in
            guard let app else { return done() }
            let profiles = Array(c.store.state.profiles.keys)
            let privateHits = profiles.flatMap { app.history.entries(ofProfile: $0) }.filter { $0.url.contains(token) }
                + profiles.flatMap { app.history.search(token, profileID: $0, limit: 8) }.map(\.entry)
            let mainHits = profiles.flatMap { app.history.entries(ofProfile: $0) }.filter { $0.url.contains(mainToken) }
            check(privateHits.isEmpty, "private (\(tag)): the private page left no history entry (\(privateHits.count))")
            check(!mainHits.isEmpty, "private (\(tag)): control: the main window's page is in history (\(mainHits.count))")
            try? c.store.flush()
            let onDisk = (try? Data(contentsOf: AppPaths.store)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            check(!onDisk.isEmpty && !onDisk.contains(token) && c.store.state.tabs.values.allSatisfy { !$0.url.contains(token) },
                  "private (\(tag)): no session-restore entry for the private page (store on disk: \(onDisk.count) bytes)")
            check(c.store.archivedEntries.allSatisfy { !$0.url.contains(token) }, "private (\(tag)): nothing of it in the Archive")
            // Its history rows come from the search above (none); its open, pinned and Favorite rows from the store.
            let rows = c.commandResults(for: token, mode: .newTab)
            check(!rows.contains { $0.subtitle.contains(token) || $0.title.contains("private one") },
                  "private (\(tag)): ⌘T in the main window doesn't offer the private page")
            #if canImport(AircCore)
            if let engine = app.engine as? ChromiumEngine, let parent = c.profiles.engineProfile(for: c.store.profile(ofSpace: c.currentSpaceID).id) {
                engine.queryHistory(token, for: parent) { rows in
                    self.check(rows.isEmpty, "private (\(tag)): Chromium's history of the profile has no row for it (\(rows.count))")
                    engine.queryHistory(mainToken, for: parent) { rows in
                        self.check(!rows.isEmpty, "private (\(tag)): control: Chromium's history has the main page (\(rows.count))")
                        done()
                    }
                }
                return
            }
            #endif
            done()
        }

        // ⌘T in the private window: its own Command Bar, no history, a tab in this window.
        run { [self] in
            guard let w = first else { return }
            postKey("t", keyCode: 17, modifiers: .command, to: w.window)
        }
        wait(0.5)
        run { [self] in
            guard let w = first else { return }
            guard let bar = w.commandBar, bar.host === w else { return check(false, "private (\(tag)): ⌘T opens the private window's Command Bar") }
            check(true, "private (\(tag)): ⌘T opens the private window's Command Bar")
            bar.type("main page")
            check(!bar.results.contains { if case .open(let u) = $0.action { u.absoluteString.contains(mainToken) } else { false } },
                  "private (\(tag)): its Command Bar offers no history (\(bar.results.map(\.badge)))")
            bar.type(base() + "/p2?" + token + "b")
            guard let pick = bar.results.first, case .open(let u) = pick.action, u.absoluteString.contains("/p2") else {
                return check(false, "private (\(tag)): the typed address is its first row (\(bar.results.map(\.title)))")
            }
            let before = c.store.state.tabs.count
            w.closeCommandBar()
            w.performCommand(pick.action, newTab: true, typed: true)
            check(w.pages.count == 2 && c.store.state.tabs.count == before, "private (\(tag)): ⌘T's pick opens a tab in the private window (\(w.pages.count) tabs)")
        }
        waitPage({ first?.shownPage }, title: "private two", "private (\(tag)): the second private tab loads")
        capturePrivate({ first }, "private-window")
        // ⌘W closes the shown tab.
        run { [self] in if let w = first { postKey("w", keyCode: 13, modifiers: .command, to: w.window) } }
        step { [self] done in
            waitUntil({ first?.pages.count == 1 }, timeout: 5) {
                self.check(first?.pages.count == 1 && first?.shownPage?.title == "private one",
                           "private (\(tag)): ⌘W closes the private tab (\(first?.pages.count ?? -1) left)")
                done()
            }
        }
        // ⇧⌘N in it: another private window, the same session.
        run { [self] in if let w = first { postKey("N", keyCode: 45, modifiers: [.command, .shift], to: w.window) } }
        step { [self] done in
            waitUntil({ browsing.windows.count == 2 }, timeout: 5) {
                second = browsing.windows.last
                self.check(browsing.windows.count == 2 && second !== first, "private (\(tag)): ⇧⌘N in a private window opens another (\(browsing.windows.count))")
                second?.openPage(URL(string: base() + "/read?" + token + "c"))
                done()
            }
        }
        waitPage({ second?.shownPage }, title: "reader", "private (\(tag)): the second private window loads")
        cookie({ second?.shownPage }) { [self] v in check(v.contains("pw=1"), "private (\(tag)): private windows share their session while one is open (\(v))") }

        // The last private window closes: the session goes; a new one starts empty.
        run {
            second?.closeWindow()
            first?.closeWindow()
        }
        step { [self] done in
            let pid = c.store.profile(ofSpace: c.currentSpaceID).id
            waitUntil({ browsing.windows.isEmpty && browsing.sessionEnded(pid, app: self.app) }, timeout: 10) {
                self.check(browsing.windows.isEmpty, "private (\(tag)): the private windows close (\(browsing.windows.count) left)")
                self.check(browsing.sessionEnded(pid, app: self.app), "private (\(tag)): closing the last one ends the private session (engine profile destroyed)")
                first = nil
                second = nil
                done()
            }
        }
        step { [self] done in
            guard let app else { return done() }
            browsing.open(app: app) { w in
                third = w
                w?.openPage(URL(string: base() + "/read?" + token + "d"))
                done()
            }
        }
        waitPage({ third?.shownPage }, title: "reader", "private (\(tag)): a new private window loads")
        cookie({ third?.shownPage }) { [self] v in
            check(!v.contains("pw=1") && !v.contains("main=1"), "private (\(tag)): a new private session has no cookie of the old one (\(v.isEmpty ? "none" : v))")
        }

        #if canImport(AircCore)
        // A DRM service's page (here localhost, chosen for Safari's engine) in WebKit: the private window's own store.
        if chromium {
            let drm = { URL(string: "http://localhost:\(port)/")! }
            run { [self] in
                ProtectedMedia.shared.choose(.webKit, for: drm())
                c.engineTab(for: mainTabID)?.close()
                if let t = try? c.store.openTab(url: base("localhost") + "/main?drm", inSpace: c.currentSpaceID, title: "drm") {
                    mainTabID = t.id
                    c.reloadAll(animated: false)
                    c.show(t.id, focus: false)
                }
            }
            waitPage({ self.c.engineTab(for: mainTabID) }, title: "main page", "private (\(tag)): the DRM-service page loads in the main window")
            step { [self] done in
                guard ProtectedMedia.isWebKitPage(c.engineTab(for: mainTabID)) else {
                    skip("private (\(tag)): DRM pages in a private window: Safari's engine isn't on for this run")
                    return done()
                }
                third?.openPage(URL(string: base("localhost") + "/read?drm"))
                waitUntil({ third?.shownPage?.title == "reader" && third?.shownPage?.isLoading == false }, timeout: 10) {
                    let p = third?.shownPage
                    self.check(ProtectedMedia.isWebKitPage(p), "private (\(tag)): a DRM service's page in a private window plays in WebKit")
                    guard let p else { return done() }
                    p.evaluate("document.cookie") { v in
                        let s = (v as? String) ?? ""
                        self.check(!s.contains("main=1"), "private (\(tag)): the private WebKit page doesn't see the profile's WebKit cookies (\(s.isEmpty ? "none" : s))")
                        done()
                    }
                }
            }
            run { ProtectedMedia.shared.choose(.chromium, for: drm()) }
        }
        #endif

        // ⇧⌘S Save Page As…, from the private window: Airc's panel with Chrome's formats, and the engine's save in each
        // format; without the engine's save (WebKit), the offer of Print → Save as PDF.
        run { [self] in third?.openPage(URL(string: base() + "/p2?" + token + "save")) }
        waitPage({ third?.shownPage }, title: "private two", "private (\(tag)): a page to save loads")
        step { [self] done in
            guard let w = third, let page = w.shownPage else { return done() }
            SavePage.offer(for: page, in: w.window) { _ in }
            waitUntil({ w.window.attachedSheet != nil }, timeout: 3) {
                let sheet = w.window.attachedSheet
                if let panel = sheet as? NSSavePanel {
                    let popup = panel.accessoryView.flatMap { v in v.subviews.compactMap { $0 as? NSPopUpButton }.first }
                    self.check(chromium && popup?.itemTitles == PageSaveFormat.allCases.map(\.title) && panel.nameFieldStringValue.hasSuffix(".html"),
                               "private (\(tag)): ⇧⌘S shows Airc's save panel with Chrome's formats (\(popup?.itemTitles ?? []), \(panel.nameFieldStringValue))")
                    panel.cancel(nil)
                } else {
                    let texts = self.sheetTexts(of: w.window)
                    self.check(!chromium && texts.contains { $0.contains("PDF ▸ Save as PDF") },
                               "private (\(tag)): without the engine's save, ⇧⌘S offers Print → Save as PDF (\(texts.first ?? "no sheet"))")
                    self.pressSheetButton("Cancel", in: w.window)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
            }
        }
        for format in PageSaveFormat.allCases where chromium {
            step { [self] done in
                guard let w = third, let page = w.shownPage, let saver = app?.engine as? EnginePageSaving else { return done() }
                let file = dir.appendingPathComponent("saved-\(format.rawValue).\(format.fileExtension)")
                try? FileManager.default.removeItem(at: file)
                guard saver.canSavePage(page) else {
                    check(false, "private (\(tag)): the engine can save the page (the framework has no save API?)")
                    return done()
                }
                saver.savePage(page, to: file, format: format) { error in
                    let body = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? ""
                    self.check(error == nil && body.contains("private two"),
                               "private (\(tag)): Save Page As \(format.title) writes the page (\(error ?? "ok"), \(body.count) bytes)")
                    done()
                }
            }
        }

        run {
            third?.closeWindow()
            server?.stop()
        }
        wait(1)
    }

    /// Waits until `tab()` shows `title`, loaded.
    private func waitPage(_ tab: @escaping () -> EngineTab?, title: String, _ what: String) {
        step { [self] done in
            waitUntil({ tab()?.title == title && tab()?.isLoading == false }, timeout: 12) {
                self.check(tab()?.title == title, what + " (\(tab()?.title ?? "no page"))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
            }
        }
    }

    private func cookie(_ tab: @escaping () -> EngineTab?, _ then: @escaping (String) -> Void) {
        step { done in
            guard let t = tab() else { then("no page"); return done() }
            t.evaluate("document.cookie") { v in
                then((v as? String) ?? "")
                done()
            }
        }
    }

    /// A key press for `window`, through the app's event queue (Airc's key monitor sees it first, as a person's).
    func postKey(_ chars: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// A private window as drawn: our views, and the page from the engine's snapshot.
    func capturePrivate(_ controller: @escaping () -> PrivateWindowController?, _ name: String) {
        step { [self] done in
            guard let w = controller() else { return done() }
            privateWindowImage(w) { img in
                if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: self.dir.appendingPathComponent(name + ".png"))
                    self.note("wrote \(name).png")
                }
                done()
            }
        }
    }

    func privateWindowImage(_ w: PrivateWindowController, _ done: @escaping (NSImage?) -> Void) {
        w.root.layoutSubtreeIfNeeded()
        w.root.displayIfNeeded()
        let overlays: [NSView] = [w.commandBar].compactMap { $0 }
        overlays.forEach { $0.isHidden = true }
        let base = render(w.root.superview ?? w.root)
        overlays.forEach { $0.isHidden = false }
        let bars = overlays.map { ($0.frame, render($0)) }
        let cardFrame = w.card.frame, size = w.root.bounds.size
        let draw = { (page: NSImage?) in
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            base?.draw(in: NSRect(origin: .zero, size: size))
            if let page {
                let r = NSRect(x: cardFrame.minX, y: size.height - cardFrame.maxY, width: cardFrame.width, height: cardFrame.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: r, xRadius: AircMetrics.Window.cardRadius, yRadius: AircMetrics.Window.cardRadius).addClip()
                page.draw(in: r)
                NSGraphicsContext.restoreGraphicsState()
            }
            for (f, img) in bars {
                img?.draw(in: NSRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height))
            }
            NSGraphicsContext.restoreGraphicsState()
            let out = NSImage(size: size)
            out.addRepresentation(rep)
            done(out)
        }
        guard let page = w.shownPage else { return draw(nil) }
        page.snapshot { draw($0) }
    }
}
#endif
