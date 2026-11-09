// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityp06d` (both engines): Arc's "Open Little Arc when clicking on links with ⌥⌘ held" (P06d,
/// Browser/LittleArcLinkClicks.swift, docs/user/little-arc.md), on loopback pages:
///   - the setting is on by default, also in settings saved before it, and off stays off;
///   - a click with ⌥⌘ in the window (a posted release, as the app sees a person's), then the page's link as both
///     engines ask for it (a background tab): a new Little Airc window with the link, in the page's Space; the page and
///     its tabs stay; one click opens one link;
///   - unchanged: ⌘ alone, a ⌥⌘ click in another window, a click over a second old, the page's own navigation, a link
///     the page opens without a click, and the setting off;
///   - in a Little Airc page, ⌥⌘ opens another Little Airc window in the same Space;
///   - links from other apps, as real GURL Apple events right after a ⌥⌘ click: Settings → Links decides, as in Arc
///     (Most recent Space: a tab in the main window; Little Airc: a Little Airc window);
///   - a real ⌥⌘-click on the page's link (posted press and release) opens it in Little Airc. The page takes it only in
///     a key window, so scripted runs, which never activate the app, report FAIL-ENV; AIRC_REAL_CLICKS=1 runs it.
extension SnapshotRunner {
    func parityP06dScenario() {
        var server: LocalPageServer?
        var base = ""
        var home = ""
        var tab = ""
        var external = ExternalLinkTarget.littleArc
        func page(_ path: String) -> String { base + path }
        func mainPage() -> EngineTab? { c.engineTab(for: tab) }
        /// A release with `flags` in the window's corner (its margin, where nothing takes it), through the app's queue.
        func release(_ flags: NSEvent.ModifierFlags, in w: NSWindow?) {
            guard let w, let e = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 3, y: 3), modifierFlags: flags,
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
            NSApp.postEvent(e, atStart: false)
        }
        /// The page's link as the engine asks the app for it after a click (the request both engines send). True: taken.
        func follow(_ path: String, from opener: EngineTab?, disposition: String = "background_tab", gesture: Bool = true) -> Bool {
            guard let opener, let url = URL(string: page(path)) else { return false }
            return app?.engine.linkRouter?(EngineLinkRequest(url: url, source: "page", disposition: disposition, sourceBundleID: nil,
                                                             userGesture: gesture, opener: opener)) == true
        }
        func littleArc(at path: String) -> LittleArcController? {
            app?.littleArcs.first { $0.page?.url.map { $0.path + ($0.query.map { "?" + $0 } ?? "") } == path }
        }

        step { [self] done in
            server = LocalPageServer(pages: [
                "/p6": "<!doctype html><title>p6</title><style>body{margin:0;font:15px -apple-system,sans-serif}</style>"
                    + "<a id=link style=\"position:absolute;left:60px;top:60px;width:220px;height:36px;display:block\" href=\"/target\">Target</a>",
                "/target": "<!doctype html><title>target</title><p>Target</p>"
            ])
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "parityp06d: a loopback page server") }
                done()
            }
        }
        closeLittleArcs()
        step { [self] done in
            app?.settingsWindow?.window.orderOut(nil)
            external = app?.settings.values.externalLinks ?? .littleArc
            home = c.currentSpaceID
            tab = (try? c.store.openTab(url: page("/p6"), inSpace: home, activate: true, title: "p6"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(tab, focus: false)
            waitUntil({ mainPage()?.isLoading == false && mainPage()?.title == "p6" }, timeout: 8) { done() }
        }

        // The setting.
        run { [self] in
            func decoded(_ json: String) -> Bool? {
                (try? JSONDecoder().decode(LittleArcGlobalSettings.self, from: Data(json.utf8)))?.opensOptionCommandClicks
            }
            let fresh = LittleArcGlobalSettings().opensOptionCommandClicks
            let older = decoded("{\"enabled\":true}"), off = decoded("{\"opensOptionCommandClicks\":false}")
            check(fresh && older == true && off == false,
                  "parityp06d: “Open Little Airc when clicking on links with ⌥⌘ held” is on by default (\(fresh)), also in settings saved "
                  + "before it (\(older.map { "\($0)" } ?? "-")), and off stays off (\(off == false))")
            app?.settings.values.littleArcGlobal.opensOptionCommandClicks = true
        }

        // ⌥⌘: a Little Airc window with the link, in the page's Space.
        var taken = false, again = false, tabsBefore = 0
        step { [self] done in
            release([.command, .option], in: c.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                tabsBefore = self.c.store.todayTabs(ofSpace: home).count
                taken = follow("/target", from: mainPage())
                again = follow("/target?again", from: mainPage())
                done()
            }
        }
        step { [self] done in
            waitUntil({ littleArc(at: "/target")?.page?.isLoading == false }, timeout: 8) {
                let l = littleArc(at: "/target")
                let stays = mainPage()?.url?.path == "/p6" && self.c.store.todayTabs(ofSpace: home).count == tabsBefore
                    && self.c.shownTabID == tab
                self.check(taken && l != nil && l?.spaceID == home && self.app?.littleArcs.count == 1 && stays && !again,
                           "parityp06d: a link clicked with ⌥⌘ opens in a new Little Airc window (taken \(taken), window \(l != nil)), in the "
                           + "page's Space (\(l?.spaceID == home)); the page and its tabs stay (\(stays)); one click opens one link (a "
                           + "second taken \(again), windows \(self.app?.littleArcs.count ?? 0))")
                done()
            }
        }

        // Unchanged without it.
        var unchanged: [(String, Bool)] = []
        func expectEngine(_ what: String, _ flags: NSEvent.ModifierFlags, in window: @escaping () -> NSWindow?, after: Double = 0.1,
                          disposition: String = "background_tab", gesture: Bool = true, setting: Bool = true) {
            step { [self] done in
                app?.settings.values.littleArcGlobal.opensOptionCommandClicks = setting
                release(flags, in: window())
                DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                    let n = self.app?.littleArcs.count ?? 0
                    let took = follow("/target?\(unchanged.count)", from: mainPage(), disposition: disposition, gesture: gesture)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        unchanged.append((what, !took && self.app?.littleArcs.count == n))
                        self.app?.settings.values.littleArcGlobal.opensOptionCommandClicks = true
                        done()
                    }
                }
            }
        }
        expectEngine("⌘ alone", [.command], in: { self.c.window })
        expectEngine("⌥⌘ in another window", [.command, .option], in: { self.app?.littleArcs.first?.window })
        expectEngine("a click 1.3 s before", [.command, .option], in: { self.c.window }, after: 1.3)
        expectEngine("the page's own navigation", [.command, .option], in: { self.c.window }, disposition: "current_tab")
        expectEngine("a link without a click", [.command, .option], in: { self.c.window }, gesture: false)
        expectEngine("the setting off", [.command, .option], in: { self.c.window }, setting: false)
        run { [self] in
            check(unchanged.count == 6 && unchanged.allSatisfy(\.1),
                  "parityp06d: the engine keeps the link (a background tab) for "
                  + unchanged.map { "\($0.0) \($0.1 ? "✓" : "✗")" }.joined(separator: ", "))
        }

        // In a Little Airc page: another Little Airc window, same Space.
        var fromLittle = false
        step { [self] done in
            guard let l = littleArc(at: "/target") else { check(false, "parityp06d: the Little Airc window from the ⌥⌘ click"); return done() }
            release([.command, .option], in: l.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                fromLittle = follow("/target?little", from: l.page)
                self.waitUntil({ littleArc(at: "/target?little")?.page?.isLoading == false }, timeout: 8) {
                    let n = littleArc(at: "/target?little")
                    self.check(fromLittle && n != nil && n !== l && n?.spaceID == l.spaceID && l.page?.url?.path == "/target",
                               "parityp06d: in a Little Airc page, ⌥⌘ opens the link in another Little Airc window in the same Space, and the "
                               + "first keeps its page (taken \(fromLittle), window \(n != nil), same Space \(n?.spaceID == l.spaceID))")
                    done()
                }
            }
        }

        // Links from other apps: Settings → Links decides, ⌥⌘ or not.
        closeLittleArcs()
        step { [self] done in
            app?.settings.values.externalLinks = .recentSpace
            release([.command, .option], in: c.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let failure = Self.sendGetURLEvent(URL(string: page("/target?ae=1"))!)
                self.waitUntil({ self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).contains { $0.url.hasSuffix("/target?ae=1") } }, timeout: 8) {
                    let inTab = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).contains { $0.url.hasSuffix("/target?ae=1") }
                    self.check(failure == nil && inTab && self.app?.littleArcs.isEmpty == true,
                               "parityp06d: a link from another app (a GURL Apple event) right after a ⌥⌘ click follows Settings → Links: "
                               + "Most recent Space opens a tab in the main window (\(inTab)), no Little Airc (\(self.app?.littleArcs.count ?? 0))"
                               + (failure.map { "; the event: \($0)" } ?? ""))
                    done()
                }
            }
        }
        step { [self] done in
            app?.settings.values.externalLinks = .littleArc
            release([.command, .option], in: c.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let failure = Self.sendGetURLEvent(URL(string: page("/target?ae=2"))!)
                self.waitUntil({ littleArc(at: "/target?ae=2") != nil }, timeout: 8) {
                    self.check(failure == nil && littleArc(at: "/target?ae=2") != nil && self.app?.littleArcs.count == 1,
                               "parityp06d: and with Little Airc, the link opens in one Little Airc window (\(self.app?.littleArcs.count ?? 0))"
                               + (failure.map { "; the event: \($0)" } ?? ""))
                    self.app?.settings.values.externalLinks = external
                    done()
                }
            }
        }

        // A real ⌥⌘-click on the page's link.
        closeLittleArcs()
        var link: NSPoint?
        step { [self] done in
            c.show(tab, focus: false)
            guard let view = mainPage()?.view else { return done() }
            mainPage()?.evaluate("(function(){var r=document.getElementById('link').getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]})()") { v in
                if let xy = (v as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), xy.count == 2 {
                    link = view.convert(NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : Double(view.bounds.height) - xy[1]), to: nil)
                }
                done()
            }
        }
        uiCase(window: { self.c.window }) {
            step { [self] done in
                guard let p = link else { check(false, "parityp06d: the page's link is on screen"); return done() }
                uiAttempt?.point = p
                func post(_ type: NSEvent.EventType) {
                    guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [.command, .option],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return }
                    NSApp.postEvent(e, atStart: false)
                }
                post(.leftMouseDown)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    post(.leftMouseUp)
                    self.waitUntil({ littleArc(at: "/target") != nil }, timeout: 4) {
                        let l = littleArc(at: "/target")
                        self.check(l != nil && mainPage()?.url?.path == "/p6",
                                   "parityp06d: a real ⌥⌘-click on the page's link opens it in Little Airc, and the page stays (window \(l != nil), "
                                   + "page \(mainPage()?.url?.path ?? "-"))")
                        done()
                    }
                }
            }
        }
        closeLittleArcs()
        run { [self] in
            app?.settings.values.externalLinks = external
            app?.settings.values.littleArcGlobal.opensOptionCommandClicks = true
            server?.stop()
        }
    }
}
#endif
