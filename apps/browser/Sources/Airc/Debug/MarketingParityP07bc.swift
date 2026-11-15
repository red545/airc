// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shots of ChatGPT in the Command Bar (P07b) and Instant Links (P07c), the marketing scenario's part
/// "parityp07bc" (`scripts/marketing-shots.sh --parts parityp07bc`):
///   - command-bar-ask-chatgpt: Travel, "gpt", Tab, a question about Lisbon: the ChatGPT pill and the row that asks it in a
///     new tab (nothing is sent: the shot is taken before Return).
///   - command-bar-instant-links: "top 3 things to do in lisbon", ⇧↵'s preview of what will open. The preview is set as
///     the resolver makes it, from public pages, so the shot needs neither Apple Intelligence nor a search request.
extension SnapshotRunner {
    func mkParityP07bcShots(_ d: MarketingDemo) {
        run { [self] in
            c.app?.settings.values.askAI.set(.chatGPT, for: d.personal)
            // ChatGPT's icon once, so the pill and the row show it rather than its letter tile.
            if let key = AskAIProvider.chatGPT.siteSearch.homeURL.flatMap(FaviconCache.guess(for:)) { FaviconCache.shared.load(key) { _ in } }
        }
        mkShow(d, "travel", "lisbon")
        mkSettleShown()
        run { [self] in
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("gpt")
        }
        wait(0.8)
        run { [self] in
            guard let bar = c.commandBar, let p = bar.askCandidate else { return note("marketing: MISSING command-bar-ask-chatgpt: no Ask row for “gpt”") }
            bar.enterScope(.ask(p))
            bar.type("Plan a relaxed day in Lisbon by tram, with a long lunch")
        }
        wait(1.2)
        run { [self] in c.commandBar?.update(allowCompletion: false) }   // the icon, now cached
        wait(0.4)
        mkWindowShot("command-bar-ask-chatgpt")
        run { [self] in
            note("marketing: ask rows: " + (c.commandBar?.resultTitles.joined(separator: " | ") ?? "-"))
            c.closeCommandBar()
        }
        wait(0.3)

        run { [self] in
            c.openCommandBar(mode: .newTab)
            let q = "top 3 things to do in lisbon"
            c.commandBar?.type(q)
            let links = [("Lisbon – Wikipedia", "https://en.wikipedia.org/wiki/Lisbon"),
                         ("Visit Lisboa – Official tourism website", "https://www.visitlisboa.com/en"),
                         ("Belém Tower – UNESCO World Heritage Centre", "https://whc.unesco.org/en/list/263/")]
                .compactMap { t, u in URL(string: u).map { InstantLink(title: t, url: $0) } }
            let plan = InstantLinksPlan(query: q, requested: 3, searchURL: SearchEngine.google.searchURL(for: q), links: links, picker: .firstResults)
            for l in links { if let key = FaviconCache.guess(for: l.url.absoluteString) { FaviconCache.shared.load(key) { _ in } } }
            c.commandBar?.showInstantPreviewForTesting(plan, engine: "Google")
        }
        wait(1.4)
        run { [self] in
            // The rows again, with the icons now cached.
            if let bar = c.commandBar, let plan = bar.instantPreview { bar.showInstantPreviewForTesting(plan, engine: "Google") }
        }
        wait(0.4)
        mkWindowShot("command-bar-instant-links")
        run { [self] in
            note("marketing: instant links rows: " + (c.commandBar?.resultTitles.joined(separator: " | ") ?? "-"))
            c.closeCommandBar()
            c.app?.settings.values.askAI.set(nil, for: d.personal)
        }
        wait(0.3)
    }
}
#endif
