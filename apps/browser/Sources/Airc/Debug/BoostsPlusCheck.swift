// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircDesign
import AircKit
import WebKit

extension SnapshotRunner {
    func boostsPlusScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        var server: LocalPageServer?
        var tabID = ""
        let site = "example.com"
        let html = "<!doctype html><html><head><title>Boost sharing</title><link rel='icon' href='data:,'></head><body><h1>Quiet reading</h1></body></html>"
        let fileURL = dir.appendingPathComponent("reading.airc-boost")
        let center = BoostCenter.shared!
        let shared = BoostFile(boost: Boost(domain: site, colors: .init(tint: 0.15), font: .init(family: .charter),
                                           css: "h1 { color: rgb(80, 40, 120) !important; }",
                                           js: "document.documentElement.dataset.sharedBoost = 'installed';"), name: "Quiet reading")
        func review() -> BoostImportReview? { BoostImportReview.active[ObjectIdentifier(self.c.window)] }
        step { [self] done in
            server = LocalPageServer(responses: ["/": .init(body: html)])
            server?.start { port in
                guard let port else { check(false, "boostsplus: loopback server starts"); return done() }
                let address = "http://example.com:\(port)/"
                guard let t = try? c.store.openTab(url: chromium ? address : "about:blank", inSpace: c.currentSpaceID) else { return done() }
                tabID = t.id; c.reloadAll(animated: false); c.show(t.id, focus: false)
                if !chromium, let page = c.engineTab(for: t.id) as? WebKitTab {
                    // WK has no resolver override: serve the same fixture at a synthetic registrable origin.
                    page.webView.loadSimulatedRequest(URLRequest(url: URL(string: address)!), responseHTML: html)
                    note("boostsplus: WebKit uses a simulated response; Chromium reaches the loopback server through host rules")
                }
                done()
            }
        }
        step { [self] done in
            waitUntil({ c.engineTab(for: tabID)?.title == "Boost sharing" && center.document(of: c.engineTab(for: tabID)!) != nil }, timeout: 12, then: done)
        }
        run { [self] in
            let menu = c.plusMenu()
            if let i = menu.items.firstIndex(where: { $0.title == "New Boost…" }) { menu.performActionForItem(at: i) }
            check(c.boostEditor?.model.domain == site, "boostsplus: + → New Boost opens editor for current site")
            check(c.commandActions().contains { $0.title == "New Boost…" }, "boostsplus: Command Bar offers New Boost")
            let combo = KeyCombo("b", [.control, .shift])
            check(KeyReservation.system[combo] == nil && CommandMenus.all.filter { $0.key == "b" && $0.modifiers == [.control, .shift] }.count == 1,
                  "boostsplus: New Boost shortcut is unreserved and unique")
            c.closeBoostEditor(animated: false)
            do { try shared.encoded().write(to: fileURL); check(true, "boostsplus: exported file written") }
            catch { check(false, "boostsplus: export \(error)") }
            // Same entry point as Finder opening a document.
            app?.application(NSApp, open: [fileURL])
        }
        wait(0.5)
        run { [self] in
            check(review()?.file.js == shared.js && review()?.sheet.isVisible == true && center.store.boost(domain: site) == nil,
                  "boostsplus: review sheet shows full JavaScript before installation")
            check(TestAnchors.frames["boost.import.cssNetworkWarning"] != nil,
                  "boostsplus: CSS review explains that styles can load external resources")
            note("boostsplus: sheet buttons driven through their own Cancel/Install actions; background SwiftUI posted clicks are unreliable")
        }
        step { [self] done in
            guard let sheet = review()?.sheet else { return done() }
            captureWindow(sheet, name: "boost-import-review", rounded: 12, done)
        }
        run { [self] in
            review()?.cancel()
            check(center.store.boost(domain: site) == nil, "boostsplus: Cancel installs nothing")
        }
        wait(0.3)
        run { [self] in
            BoostSharing.open(fileURL, on: c.window)
            review()?.install()
            check(center.store.boost(domain: site)?.js == shared.js, "boostsplus: Install stores reviewed code")
        }
        step { [self] done in
            let deadline = Date().addingTimeInterval(6)
            func probe() {
                c.engineTab(for: tabID)?.evaluate("document.documentElement.dataset.sharedBoost + '|' + getComputedStyle(document.querySelector('h1')).color") { value in
                    let result = String(describing: value ?? "nil")
                    if result.contains("installed|rgb(80, 40, 120)") { check(true, "boostsplus: installed JS and CSS apply to page"); done() }
                    else if Date() > deadline { check(false, "boostsplus: installed JS/CSS: \(result)"); done() }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: probe) }
                }
            }
            probe()
        }
        run { [self] in
            BoostSharing.open(fileURL, on: c.window)
            check(review()?.existing?.js == shared.js, "boostsplus: replacement shows existing Boost and full code")
            review()?.cancel()
        }
        wait(0.3)
        run { [self] in
            let bad = dir.appendingPathComponent("malformed.airc-boost")
            try? Data("{\"version\":99}".utf8).write(to: bad)
            check(!BoostSharing.open(bad, on: c.window) && review() == nil && c.window.attachedSheet != nil,
                  "boostsplus: malformed file refused with a message")
            if let sheet = c.window.attachedSheet { c.window.endSheet(sheet); sheet.orderOut(nil) }
            server?.stop()
        }
        wait(0.3)
        run { [self] in
            c.showEmpty()
            c.newBoost()
            check(c.window.attachedSheet != nil && c.boostEditor == nil, "boostsplus: without a site New Boost asks for one")
            if let sheet = c.window.attachedSheet { c.window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil) }
        }
    }

    func mkBoostSharingShot() {
        run { [self] in
            let file = BoostFile(boost: Boost(domain: "wikipedia.org", colors: .init(hue: 0.1, tint: 0.18),
                                              font: .init(family: .charter, size: 1), css: ".mw-body { max-width: 72ch; margin: auto; }",
                                              js: "// Add a reading label to the page.\nconst label = document.createElement('p');\nlabel.textContent = 'Time to explore something new.';\ndocument.querySelector('main')?.prepend(label);",
                                              scriptHost: "en.wikipedia.org"), name: "A little room to read")
            if let center = BoostCenter.shared { BoostImportReview(file: file, source: .file, parent: c.window, controller: c, center: center).present() }
        }
        wait(0.6)
        step { [self] done in
            guard let sheet = BoostImportReview.active[ObjectIdentifier(c.window)]?.sheet else { return done() }
            captureWindow(sheet, name: "boost-import", rounded: 12, done)
        }
        run { [self] in BoostImportReview.active[ObjectIdentifier(c.window)]?.cancel() }
    }
}
#endif
