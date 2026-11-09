// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityp08c` (P08c, docs/qa/parity-audit.md N02, docs/user/parity-p08c.md), both engines, a loopback page:
///   1. View has Capture…, Capture Full Page and Capture in Portrait Mode together (Portrait without a key, as Arc's);
///      the Command Bar offers Capture in Portrait Mode once (its own row, not a second copy from the menu catalog).
///   2. View › Capture in Portrait Mode, fired as the menu fires it: Capture starts straight in Portrait, the page framed
///      on the default colour; the desktop picture is never read (the check's own stands in, and counts reads); Esc-like
///      cancel leaves no session.
///   3. The Site Control Center: Capture and Capture in Portrait Mode beside Copy link, clicked for real. Each closes
///      the card first; Capture starts at the selection, Portrait framed. Cancel leaves nothing.
/// The portrait style lives in a suite of the check's own (never the person's choices). Nothing is copied or saved.
extension SnapshotRunner {
    func parityP08cScenario() {
        let tag = app?.engine is WebKitEngine ? "parityp08c (WebKit)" : "parityp08c (Chromium)"
        var server: LocalPageServer?, tab = ""
        var wallpaperReads = 0
        let suiteName = "org.airc.test.p08c.\(getpid())"
        let realWallpaper = PortraitCapture.wallpaper
        let page = { self.c.engineTab(for: tab) }
        let active = { CaptureSession.active(in: self.c.window) }
        let viewMenu = { NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu }
        let body = "<!doctype html><title>P08c page</title><style>html,body{margin:0;height:100%;background:#2f80ed}"
            + "h1{font:600 48px -apple-system;color:#fff;padding:60px}</style><h1>Capture entry points</h1>"

        step { [self] done in
            UserDefaults().removePersistentDomain(forName: suiteName)
            PortraitStyle.storage = { UserDefaults(suiteName: suiteName)! }
            PortraitCapture.wallpaper = { _, _ in wallpaperReads += 1; return nil }
            server = LocalPageServer(pages: ["/p08c.html": body])
            server?.start { port in
                guard let port, let t = try? self.c.store.openTab(url: "http://127.0.0.1:\(port)/p08c.html", inSpace: self.c.currentSpaceID) else {
                    self.check(false, "\(tag): the loopback page opens"); return self.finish()
                }
                tab = t.id
                self.c.reloadAll(animated: false)
                self.c.show(tab, focus: false)
                self.waitUntil({ page()?.title == "P08c page" && page()?.isLoading == false }, timeout: 15) { done() }
            }
        }
        wait(0.8)

        /// Waits for a session that is (portrait) framed and confirmed, or (plain) selecting with its pictures in.
        func expectSession(_ portrait: Bool, _ what: String) {
            step { [self] done in
                waitUntil({
                    guard let s = active() else { return false }
                    return portrait ? s.phase == .confirmed && s.portrait != nil : s.picturesReady && s.phase == .selecting
                }, timeout: portrait ? 40 : 10) {
                    let s = active()
                    self.check(s != nil && (portrait ? s?.portrait != nil && s?.phase == .confirmed : s?.portrait == nil && s?.phase == .selecting),
                               "\(tag): \(what) (session \(s == nil ? "none" : "\(s!.phase)"), portrait \(s?.portrait != nil))")
                    done()
                }
            }
        }
        func cancelSession(_ what: String) {
            run { [self] in active()?.cancel() }
            step { [self] done in
                waitUntil({ active() == nil }, timeout: 3) {
                    self.check(active() == nil, "\(tag): \(what): cancel leaves no Capture behind")
                    done()
                }
            }
            wait(0.3)
        }

        // 1. The menu and the Command Bar.
        run { [self] in
            let items = viewMenu()?.items.filter { !$0.isSeparatorItem } ?? []
            let titles = items.map(\.title)
            let at = titles.firstIndex(of: "Capture…") ?? -1
            let run3 = at >= 0 ? Array(titles[at..<min(at + 3, titles.count)]) : []
            check(run3 == ["Capture…", "Capture Full Page", "Capture in Portrait Mode"],
                  "\(tag): View has Capture…, Capture Full Page, Capture in Portrait Mode together (\(run3))")
            let portrait = items.first { $0.title == "Capture in Portrait Mode" }
            check(portrait is CommandMenuItem && portrait?.keyEquivalent == "" && portrait?.isEnabled == true,
                  "\(tag): View › Capture in Portrait Mode is a browser command without a key, enabled")
            check(CommandMenus.all.contains { $0.id == "view.capturePortrait" && $0.title == "Capture in Portrait Mode" },
                  "\(tag): its command id is view.capturePortrait (Settings → Shortcuts can give it a key)")
            let rows = c.commandActions().filter { $0.title == "Capture in Portrait Mode" }.count
            check(rows == 1, "\(tag): the Command Bar has Capture in Portrait Mode once (\(rows))")
        }

        // 2. View › Capture in Portrait Mode, as the menu fires it.
        run { [self] in
            if let item = viewMenu()?.items.first(where: { $0.title == "Capture in Portrait Mode" }) as? CommandMenuItem { item.fire() }
            else { check(false, "\(tag): View › Capture in Portrait Mode exists to fire") }
        }
        expectSession(true, "View › Capture in Portrait Mode frames the page")
        run { [self] in
            let s = active()
            check(s?.portrait?.style.background == PortraitStyle().background && s?.portrait?.tab === page(),
                  "\(tag): the portrait is of the page on screen, on the default background (\(String(describing: s?.portrait?.style.background)))")
            check(wallpaperReads == 0, "\(tag): the desktop picture was never read (\(wallpaperReads) reads)")
        }
        cancelSession("View › Capture in Portrait Mode")

        // 3. The Site Control Center's buttons, clicked.
        func openCard() {
            run { [self] in if c.siteControls == nil { c.toggleSiteControls() } }
            step { [self] done in
                waitUntil({ self.c.siteControls != nil && TestAnchors.frames["site.capturePortrait"] != nil }, timeout: 3) {
                    self.check(self.c.siteControls != nil, "\(tag): the Site Control Center opens")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                }
            }
        }
        openCard()
        run { [self] in
            let f = TestAnchors.frames
            let cap = f["site.capture"], por = f["site.capturePortrait"], copy = f["site.copy"]
            check(cap != nil && por != nil && copy != nil && cap!.maxX <= por!.minX + 0.5 && por!.maxX <= copy!.minX + 0.5
                  && abs(cap!.midY - copy!.midY) < 1 && abs(por!.midY - copy!.midY) < 1,
                  "\(tag): the card's header has Capture, Capture in Portrait Mode, Copy link in a row "
                  + "(\(cap.map { NSStringFromRect($0) } ?? "-"), \(por.map { NSStringFromRect($0) } ?? "-"), \(copy.map { NSStringFromRect($0) } ?? "-"))")
        }
        capture(app?.engine is WebKitEngine ? "parityp08c-sitecontrols" : "parityp08c-sitecontrols-chromium")
        clickIn({ self.c.siteControls?.hostingView }, "site.capture")
        expectSession(false, "the Site Control Center's Capture starts Capture at the selection")
        run { [self] in
            check(c.siteControls == nil, "\(tag): Capture closed the Site Control Center (\(TestAnchors.lastHit["site.capture"] ?? "-"))")
        }
        cancelSession("the Site Control Center's Capture")
        openCard()
        clickIn({ self.c.siteControls?.hostingView }, "site.capturePortrait")
        run { [self] in
            note("\(tag): after the Portrait click: card \(c.siteControls == nil ? "closed" : "open"), session "
                 + (active().map { "\($0.phase), pictures \($0.picturesReady), portrait \($0.portrait != nil)" } ?? "none")
                 + ", toast \(c.toast.shownText ?? "none"), page view hidden \(page()?.view.isHiddenOrHasHiddenAncestor ?? true), card \(NSStringFromRect(c.card.frame))")
        }
        expectSession(true, "the Site Control Center's Capture in Portrait Mode frames the page")
        run { [self] in
            check(c.siteControls == nil, "\(tag): Portrait closed the Site Control Center (\(TestAnchors.lastHit["site.capturePortrait"] ?? "-"))")
            check(active()?.portrait?.tab === page(), "\(tag): and framed the page on screen")
            check(wallpaperReads == 0, "\(tag): still no desktop picture read (\(wallpaperReads))")
        }
        cancelSession("the Site Control Center's Capture in Portrait Mode")

        run { [self] in
            PortraitStyle.storage = { .standard }
            PortraitCapture.wallpaper = realWallpaper
            UserDefaults().removePersistentDomain(forName: suiteName)
            server?.stop()
            note("\(tag): done (window key \(c.window.isKeyWindow))")
        }
    }
}
#endif
