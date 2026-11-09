// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script parityp07d` (P07d, docs/qa/parity-audit.md C08, docs/user/parity-p07d.md), both engines, a loopback site:
///   1. A profile with no default site searches its built-in engine. A site search of its own (a loopback "find" page)
///      made the default in Settings → Site Search is what it searches now, and that survives a settings reload.
///   2. Settings → Site Search shows the "Search with" choice (drawn to parityp07d-settings.png).
///   3. The URL field (the page toolbar's address field): typed words go to the default site, encoded as its site search
///      encodes them (the loopback server sees the request); an address typed still opens as an address.
///   4. The default site removed: the profile falls back to its built-in engine (nothing is loaded from the web).
///   5. The Command Bar's search row: logged (its hook in CommandBar.swift is P03b's file tonight; REPORT.md).
/// Nothing leaves the machine: the only page loaded is on 127.0.0.1.
extension SnapshotRunner {
    func parityP07dScenario() {
        let tag = app?.engine is WebKitEngine ? "parityp07d (WebKit)" : "parityp07d (Chromium)"
        var server: LocalPageServer?
        var port: UInt16 = 0
        var tab = "", siteID = ""
        var openedToolbar = false
        let lock = NSLock()
        var requests: [String] = []
        let page = { self.c.engineTab(for: tab) }
        let profile = { self.c.store.profile(ofSpace: self.c.currentSpaceID) }
        let query = "wool & socks 東京"
        // As SiteSearchTemplate.expand encodes a query value (Chromium's EscapeQueryParamValue).
        let encoded = "wool+%26+socks+%E6%9D%B1%E4%BA%AC"

        step { [self] done in
            server = LocalPageServer(pages: ["/start.html": "<!doctype html><title>P07d start</title><p>start</p>",
                                             "/find": "<!doctype html><title>P07d results</title><p>results</p>"])
            server?.handler = { path in lock.withLock { requests.append(path) }; return nil }
            server?.start { p in
                guard let p, let t = try? self.c.store.openTab(url: "http://127.0.0.1:\(p)/start.html", inSpace: self.c.currentSpaceID) else {
                    self.check(false, "\(tag): the loopback site opens"); return self.finish()
                }
                port = p
                tab = t.id
                self.c.reloadAll(animated: false)
                self.c.show(tab, focus: false)
                self.waitUntil({ page()?.title == "P07d start" && page()?.isLoading == false }, timeout: 15) { done() }
            }
        }

        // 1. The model, in the app's settings.
        run { [self] in
            guard let settings = app?.settings else { return check(false, "\(tag): the app's settings") }
            let p = profile()
            check(p.defaultSearch == .engine(p.searchEngine), "\(tag): with no default site, the profile searches \(p.searchEngine.name)")
            switch settings.values.siteSearch.add(name: "Loopback Find", keyword: "lf", template: "http://127.0.0.1:\(port)/find?q=%s", to: p.id) {
            case .success(let s): siteID = s.id
            case .failure(let e): check(false, "\(tag): the loopback site search is accepted (\(e.message))")
            }
            check(settings.values.siteSearch.setDefault(siteID, for: p.id), "\(tag): the site can be made the default")
            check(profile().defaultSearch.site?.id == siteID && profile().defaultSearch.name == "Loopback Find",
                  "\(tag): the profile's default search is now the site (\(profile().defaultSearch.name))")
            let restored = AppSettings(directory: AppPaths.dataDirectory)
            check(restored.values.siteSearch.defaultSite(for: p.id)?.id == siteID, "\(tag): the default site survives a settings reload")
        }

        // 2. Settings → Site Search.
        run { [self] in app?.showSettings(page: .siteSearch) }
        step { [self] done in
            waitUntil({ TestAnchors.frames["sitesearch.default"] != nil }, timeout: 3) {
                self.check(TestAnchors.frames["sitesearch.default"] != nil, "\(tag): Settings → Site Search has the Search with choice")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
        }
        run { [self] in
            if let w = app?.settingsWindow?.window, let v = w.contentView {
                v.layoutSubtreeIfNeeded()
                if let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    let name = app?.engine is WebKitEngine ? "parityp07d-settings.png" : "parityp07d-settings-chromium.png"
                    try? png.write(to: dir.appendingPathComponent(name))
                    note("wrote \(name)")
                }
            }
            app?.settingsWindow?.window.close()
        }

        // 3. The URL field: words go to the default site; an address still opens.
        func typeInToolbar(_ text: @escaping () -> String) {
            run { [self] in
                let text = text()
                if c.pageToolbar == nil { c.togglePageToolbar(); openedToolbar = true }
                guard let t = c.pageToolbar else { return check(false, "\(tag): the page toolbar shows") }
                t.address.stringValue = text
                _ = t.control(t.address, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            }
        }
        run { lock.withLock { requests.removeAll() } }
        typeInToolbar { query }
        step { [self] done in
            let want = "http://127.0.0.1:\(port)/find?q=\(encoded)"
            waitUntil({ page()?.url?.absoluteString == want && page()?.isLoading == false }, timeout: 15) {
                let got = page()?.url?.absoluteString ?? "-"
                let asked = lock.withLock { requests.contains("/find") }
                self.check(got == want && asked && page()?.title == "P07d results",
                           "\(tag): the URL field searches the default site, encoded as its site search (\(got), server asked: \(asked))")
                done()
            }
        }
        typeInToolbar { "http://127.0.0.1:\(port)/start.html" }
        step { [self] done in
            let want = "http://127.0.0.1:\(port)/start.html"
            waitUntil({ page()?.url?.absoluteString == want && page()?.title == "P07d start" && page()?.isLoading == false }, timeout: 15) {
                self.check(page()?.url?.absoluteString == want && page()?.title == "P07d start",
                           "\(tag): an address typed in the URL field still opens (\(page()?.url?.absoluteString ?? "-"))")
                done()
            }
        }

        // 5. The Command Bar's search row (logged; see the scenario's comment).
        run { [self] in
            let rows = c.commandResults(for: "wool socks", mode: .newTab, inline: nil, inlineSite: nil, suggestions: [], history: [])
            var url: URL?
            if let r = rows.first(where: { $0.badge == "Search" }), case .open(let u) = r.action { url = u }
            check(url?.absoluteString == "http://127.0.0.1:\(port)/find?q=wool+socks" && rows.first(where: { $0.badge == "Search" })?.subtitle.contains("Loopback Find") == true,
                  "\(tag): the Command Bar's search row searches the default site (\(url?.absoluteString ?? "-"))")
        }

        // 4. The default site removed: back to the built-in engine.
        run { [self] in
            guard let settings = app?.settings else { return }
            let p = profile()
            settings.values.siteSearch.remove(siteID, from: p.id)
            let now = profile().defaultSearch
            let resolved = URLRules.resolve("wool socks", search: now)
            check(now == .engine(p.searchEngine) && resolved == p.searchEngine.searchURL(for: "wool socks"),
                  "\(tag): with the site removed, the profile searches \(p.searchEngine.name) again (\(resolved?.host ?? "-"))")
            check(AppSettings(directory: AppPaths.dataDirectory).values.siteSearch.defaultSite(for: p.id) == nil,
                  "\(tag): and that is what is saved")
        }

        run { [self] in
            if openedToolbar, c.pageToolbar != nil { c.togglePageToolbar() }
            server?.stop()
            note("\(tag): done")
        }
    }
}
#endif
