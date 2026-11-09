// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shots of Arc's Site Search (P07a), the marketing scenario's part "parityp07"
/// (`scripts/marketing-shots.sh --parts parityp07`):
///   - command-bar-site-search: Travel, "wiki", Tab, "Belém Tower": the Wikipedia pill leading the field, the search and
///     the Wikipedia pages of the demo's own history under it.
///   - command-bar-site-search-hint: "wiki" typed: the "Search Wikipedia · Press Tab" row under the top hit.
///   - settings-site-search: Settings → Site Search, Wikipedia as the profile's default search engine (P07d, marked
///     Default in the list), the default sites and the add form.
extension SnapshotRunner {
    func mkParityP07Shots(_ d: MarketingDemo) {
        run { [self] in
            // The demo's history has Lisbon's Wikipedia pages (MarketingScenario.mkSeed); two more for Belém, made up.
            if let h = c.app?.history {
                for (url, title) in [("https://en.wikipedia.org/wiki/Bel%C3%A9m_Tower", "Belém Tower – Wikipedia"),
                                     ("https://en.wikipedia.org/wiki/Jer%C3%B3nimos_Monastery", "Jerónimos Monastery – Wikipedia")] {
                    for _ in 0..<2 { h.recordVisit(profileID: d.personal, url: url, title: title, typed: false) }
                }
            }
            // Wikipedia's icon once, so the rows and the pill show it rather than its letter tile.
            if let key = SiteSearchSettings.defaults.first(where: { $0.name == "Wikipedia" })?.homeURL.flatMap(FaviconCache.guess(for:)) {
                FaviconCache.shared.load(key) { _ in }
            }
        }
        mkShow(d, "travel", "lisbon")
        mkSettleShown()
        run { [self] in
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("wiki")
        }
        wait(1.2)
        mkWindowShot("command-bar-site-search-hint")
        run { [self] in
            note("marketing: site search hint rows: " + (c.commandBar?.resultTitles.joined(separator: " | ") ?? "-"))
            guard let bar = c.commandBar, let s = bar.siteCandidate else { return note("marketing: MISSING command-bar-site-search: no site for “wiki”") }
            bar.enterScope(.site(s))
            bar.type("Belém Tower")
        }
        wait(1.4)
        run { [self] in c.commandBar?.update(allowCompletion: false) }   // the rows again, with the icon now cached
        wait(0.4)
        mkWindowShot("command-bar-site-search")
        run { [self] in
            note("marketing: site search rows: " + (c.commandBar?.resultTitles.joined(separator: " | ") ?? "-"))
            c.closeCommandBar()
        }
        wait(0.3)

        // Settings → Site Search, as the settings part shoots its pages, with Wikipedia as the default engine (P07d).
        run { [self] in
            c.app?.settings.values.siteSearch.setDefault("default.wikipedia", for: d.personal)
            NSApp.appearance = NSAppearance(named: .aqua)
            c.app?.showSettings(page: .siteSearch)
            if let w = c.app?.settingsWindow?.window { w.setFrameOrigin(NSPoint(x: -6000, y: 200)) }
        }
        wait(0.9)
        step { [self] done in
            defer { done() }
            guard let w = c.app?.settingsWindow?.window, let view = w.contentView, let img = mkContentImage(w) else {
                return note("marketing: MISSING settings-site-search: no Settings window")
            }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("settings-site-search", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w)),
            ])
        }
        run { [self] in
            c.app?.settingsWindow?.window.orderOut(nil)
            c.app?.settings.values.siteSearch.setDefault(nil, for: d.personal)
        }
    }
}
#endif
