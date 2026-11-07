// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script keeploaded` (both engines; MEM-3's exemption, Browser/TabUnloading.swift), on loopback pages with a 2 s
/// unload timeout and "localhost" on the never-unload list (AircKit's KeepLoadedSites, as a test entry):
///   - a pinned tab and a Favorite on the listed host stay loaded; a pinned tab on an unlisted host (127.0.0.1) and a
///     Today tab on the listed host unload;
///   - with Settings → General → "Keep chat and mail sites loaded" off, the listed pinned tab and Favorite unload too;
///   - Chromium build: the same for WebKit pages (both hosts set to play in Safari's engine).
/// Chromium pressure check also requires --airc-data-dir=<same folder as --data-dir> (scratch-only engine gate).
/// No account, no camera, microphone or screen.
extension SnapshotRunner {
    func keepLoadedScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        var server: LocalPageServer?
        var port: UInt16 = 0
        var space = ""
        func url(_ host: String, _ path: String) -> String { "http://\(host):\(port)\(path)" }
        let page = { (title: String) in "<!doctype html><title>\(title)</title><h1>\(title)</h1>" }

        step { [self] done in
            var pages: [String: String] = [:]
            for p in ["chat", "plain", "mail", "today", "shown"] {
                for n in ["", "2"] { pages["/\(p)\(n)"] = page(p + n) }
            }
            server = LocalPageServer(pages: pages)
            guard let server else { check(false, "keep loaded: the loopback server starts"); return done() }
            server.start { p in
                if let p { port = p } else { self.check(false, "keep loaded: the loopback server starts") }
                done()
            }
        }
        run { [self] in
            WindowController.keepLoadedTestSites = ["localhost"]
            app?.settings.values.keepChatSitesLoaded = true
            // Leaving a tab must not put anything in picture in picture (it would keep the page).
            app?.settings.values.pipAutomatic = false
            c.applyPictureInPictureSettings()
            space = c.currentSpaceID
            check(app?.settings.values.keepChatSitesLoaded == true && Values().keepChatSitesLoaded,
                  "keep loaded: \"Keep chat and mail sites loaded\" is on by default")
        }

        /// One round: the four tabs, each shown once, then a fifth shown; after the timeout, which pages are left.
        func round(_ label: String, suffix: String, webKit: Bool) {
            var ids: [String: String] = [:]
            let kinds = ["chat", "plain", "mail", "today", "shown"]
            step { [self] done in
                guard port != 0 else { return done() }
                do {
                    let pid = c.store.profile(ofSpace: space).id
                    for k in kinds {
                        let host = ["plain", "shown"].contains(k) ? "127.0.0.1" : "localhost"
                        let t = try c.store.openTab(url: url(host, "/\(k)\(suffix)"), inSpace: space, activate: false, title: k)
                        ids[k] = t.id
                        if k == "chat" || k == "plain" { try c.store.togglePin(t.id, inSpace: space) }
                        if k == "mail" { try c.store.move(.tab(t.id), to: .favorites(profileID: pid, index: 0)) }
                    }
                } catch { check(false, "keep loaded \(label): setup (\(error))") }
                WindowController.unloadOverride = 2
                c.applyUnloadSetting()
                c.reloadAll(animated: false)
                done()
            }
            for k in kinds {
                step { [self] done in
                    guard let id = ids[k] else { return done() }
                    c.show(id, focus: false)
                    waitUntil({ self.c.engineTab(for: id)?.title == k + suffix && self.c.engineTab(for: id)?.isLoading == false }, timeout: 8) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                    }
                }
            }
            run { [self] in
                let pages = kinds.compactMap { ids[$0] }.compactMap { c.engineTab(for: $0) }
                let engines = pages.map { ProtectedMedia.isWebKitPage($0) || !chromium ? "WebKit" : "Chromium" }
                check(pages.count == kinds.count && Set(engines).count == 1 && (chromium ? (engines.first == "WebKit") == webKit : true),
                      "keep loaded \(label): the five pages load (\(engines.joined(separator: ", ")))")
                check(c.store.tab(ids["chat"])?.isToday == false && c.store.item(c.store.tab(ids["mail"])?.itemID)?.isFavorite == true
                      && c.store.tab(ids["today"])?.isToday == true, "keep loaded \(label): a pinned tab, a Favorite, a Today tab")
            }
            let unloaded = { (k: String) in self.c.isPageUnloaded(ids[k]) }
            step { [self] done in
                // 2 s, the check's coalescing and the input check in the page.
                waitUntil({ unloaded("plain") && unloaded("today") }, timeout: 10) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: done)
                }
            }
            run { [self] in
                check(!unloaded("chat"), "keep loaded \(label): a pinned tab on a listed site stays loaded")
                check(!unloaded("mail"), "keep loaded \(label): a Favorite on a listed site stays loaded")
                check(unloaded("plain"), "keep loaded \(label): a pinned tab on an unlisted site unloads")
                check(unloaded("today"), "keep loaded \(label): a Today tab on a listed site unloads (only pinned tabs and Favorites stay)")
                check(!unloaded("shown"), "keep loaded \(label): the tab on screen stays")
            }
            #if canImport(AircCore)
            if chromium && !webKit {
                run { [self] in
                    check(!c.appUnloadsChromiumPages, "keep loaded: Chromium owns its timeout")
                    // Disable the timeout: only the pressure signal may discard this fresh control.
                    WindowController.unloadOverride = 0
                    c.applyUnloadSetting()
                    if let id = ids["plain"] { c.show(id, focus: false) }
                }
                step { [self] done in
                    waitUntil({ ids["plain"].flatMap { self.c.engineTab(for: $0) }?.isLoading == false && !unloaded("plain") }, timeout: 8) { done() }
                }
                run { [self] in if let id = ids["shown"] { c.show(id, focus: false) } }
                wait(1)
                run { [self] in check(AircEngine.simulateMemoryPressure(forTesting: 2), "keep loaded: engine pressure hook accepted") }
                step { [self] done in
                    waitUntil({ unloaded("plain") }, timeout: 5) {
                        self.check(unloaded("plain"), "keep loaded: pressure unloads the unlisted control with timeout disabled")
                        self.check(!unloaded("chat") && !unloaded("mail"), "keep loaded: pressure preserves listed pin and Favorite")
                        done()
                    }
                }
            }
            #endif
            run { [self] in
                WindowController.unloadOverride = 2
                app?.settings.values.keepChatSitesLoaded = false
                c.applyUnloadSetting()
            }
            step { [self] done in
                waitUntil({ unloaded("chat") && unloaded("mail") }, timeout: 10) {
                    self.check(unloaded("chat") && unloaded("mail"),
                               "keep loaded \(label): with the setting off, they unload too (pinned \(unloaded("chat")), Favorite \(unloaded("mail")))")
                    done()
                }
            }
            run { [self] in
                app?.settings.values.keepChatSitesLoaded = true
                WindowController.unloadOverride = nil
                c.applyUnloadSetting()
                for k in kinds {
                    guard let id = ids[k] else { continue }
                    if let iid = c.store.tab(id)?.itemID { try? c.store.deleteItem(iid) } else { c.closeTab(id) }
                }
                c.reloadAll(animated: false)
            }
            wait(0.5)
        }

        round(chromium ? "(chromium, Chromium pages)" : "(webkit)", suffix: "", webKit: !chromium)
        #if canImport(AircCore)
        if chromium {
            run { ProtectedMedia.shared.testHosts = ["localhost", "127.0.0.1"] }
            round("(chromium, WebKit pages)", suffix: "2", webKit: true)
            run { ProtectedMedia.shared.testHosts = [] }
        }
        #endif
        run { [self] in
            WindowController.keepLoadedTestSites = []
            server?.stop()
        }
        wait(0.5)
    }

    private typealias Values = AppSettings.Values
}
#endif
