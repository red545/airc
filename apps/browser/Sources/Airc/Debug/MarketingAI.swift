// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The marketing shots of the AI features (docs/user/ai.md), the marketing scenario's part "ai"
/// (`scripts/marketing-shots.sh --parts ai`), with Apple Intelligence's real answers: on a Mac without it every shot is
/// MISSING. Demo pages of our own (MarketingServer's extra pages, reached as *.aircbrowser.com; no site's content):
///   - ai-ask-page: Travel on a synthetic Lisbon guide, ⌘F in Ask mode with the model's answer, its quote under it and the
///     page scrolled to the quote, highlighted;
///   - ai-link-preview: a synthetic reading list with ⇧ over a link: the card with the model's summary of the article;
///   - ai-tidy-downloads: Library › Downloads after "IMG_2041 (1).pdf" (a synthetic itinerary) came in: the model's
///     suggested name and Rename;
///   - ai-settings: Settings → AI with every feature on, the window tall enough for all of it.
/// The ⇧-hover is the page's own event, dispatched on the link, with the check's stand-in for the person's ⇧
/// (LinkPreviewFeature.trustSynthetic / input): the scripted run can't post real input.
extension SnapshotRunner {
    static let mkAIStyle = """
    <style>
    body{margin:0;font:18px/1.62 ui-serif,Georgia,serif;color:#23262b;background:#fbfaf7}
    main{max-width:700px;margin:0 auto;padding:64px 40px 120px}
    .kicker{font:600 13px -apple-system,sans-serif;letter-spacing:.12em;text-transform:uppercase;color:#b4553b}
    h1{font:700 46px/1.1 ui-rounded,-apple-system,sans-serif;letter-spacing:-.8px;margin:10px 0 18px}
    h2{font:650 24px -apple-system,sans-serif;margin:38px 0 6px}
    .lede{font-size:21px;color:#5b616a}
    a{color:#2a5bd7;text-decoration-thickness:1px;text-underline-offset:3px}
    .meta{font:14px -apple-system,sans-serif;color:#8a8f96;margin-bottom:28px}
    .item{padding:18px 0;border-top:1px solid #ece8e1}.item p{margin:4px 0 0;color:#6b7078;font-size:16px}
    .item a{font:600 20px -apple-system,sans-serif;text-decoration:none;color:#1f2a44}
    .btn{display:inline-block;font:600 15px -apple-system,sans-serif;background:#1f2a44;color:#fff;border-radius:10px;padding:10px 16px;text-decoration:none}
    </style>
    """

    static let mkAIGuide = "<!doctype html><meta charset=\"utf-8\"><title>Lisbon in three days – Example Travel</title>" + mkAIStyle + """
    <main><div class="kicker">City guide</div><h1>Lisbon in three days</h1>
    <p class="lede">Hills, trams and tiled façades: an easy plan for the old town, Belém and the river.</p>
    <div class="meta">Updated 2 November · 6 min read</div>
    <h2>Day one: Alfama</h2>
    <p>Start early in Alfama, before the tour groups. The Castelo de São Jorge opens at 9:00 and closes at 21:00 from March to October; tickets cost fifteen euros, and children under twelve go free.</p>
    <p>Walk down through the lanes to the Miradouro de Santa Luzia for the view over the river, then catch tram 28 towards Baixa. It runs every twelve minutes; buy a Viva Viagem card at any metro station.</p>
    <h2>Day two: Belém</h2>
    <p>Take the train or tram 15 to Belém. The Jerónimos Monastery is closed on Mondays, so plan this day for later in the week. Pastéis de Belém sells about 20,000 custard tarts a day, and the queue moves fast.</p>
    <h2>Day three: Sintra</h2>
    <p>Trains to Sintra leave Rossio station every twenty minutes, and the trip takes about forty minutes. Book the Pena Palace for the first slot of the morning.</p>
    </main>
    """

    static let mkAIReading = "<!doctype html><meta charset=\"utf-8\"><title>Weekend reading – Example News</title>" + mkAIStyle + """
    <main><div class="kicker">Weekend reading</div><h1>Five things worth your time</h1>
    <p class="lede">Hand-picked stories from the week, for a slow Saturday morning.</p>
    <div class="item"><a id="harbour" href="http://news.aircbrowser.com/harbour">The old harbour is opening again</a><p>A city waterfront, three years in the making.</p></div>
    <div class="item"><a href="http://news.aircbrowser.com/night-trains">Night trains are back</a><p>Sleeper routes across Europe, from Vienna to Brussels.</p></div>
    <div class="item"><a href="http://news.aircbrowser.com/bread">The bakery that never sleeps</a><p>Inside a 24-hour neighbourhood bakery.</p></div>
    <div class="item"><a href="http://news.aircbrowser.com/gardens">Rooftop gardens, one balcony at a time</a><p>How a block of flats grew its own vegetables.</p></div>
    </main>
    """

    static let mkAIHarbour = "<!doctype html><meta charset=\"utf-8\"><title>The old harbour is opening again – Example News</title>" + mkAIStyle + """
    <main><div class="kicker">City</div><h1>The old harbour is opening again</h1>
    <p class="lede">After three years of building work, the city's old harbour reopens to visitors in May.</p>
    <p>The project turned the derelict docks into a public waterfront. The old brick warehouses have become a covered market hall with twenty food stalls and a fish market that opens at six in the morning.</p>
    <p>Ferries to the three islands in the bay will leave every hour from the new pier, starting at seven. A return ticket costs eight euros, and bicycles travel free.</p>
    <p>There is space for 400 bicycles by the market hall, but no car parking: the city expects most visitors to come by tram line 4, which now runs to the waterfront every ten minutes.</p>
    <p>The opening weekend, on 16 and 17 May, has free concerts on the quay and guided walks through the restored warehouses.</p>
    </main>
    """

    static let mkAITrip = "<!doctype html><meta charset=\"utf-8\"><title>Your trip to Lisbon – Example Travel</title>" + mkAIStyle + """
    <main><div class="kicker">Your trip</div><h1>Lisbon, 12–15 March</h1>
    <p class="lede">Everything for your three days in Lisbon, in one place.</p>
    <p><a class="btn" href="/ai/files/IMG_2041%20(1).pdf">Download your itinerary</a></p>
    </main>
    """

    @MainActor func mkAIShots(_ d: MarketingDemo) {
        let ai = AIFeatures.shared
        guard ai.availability == .available else {
            for n in ["ai-ask-page", "ai-link-preview", "ai-tidy-downloads", "ai-settings"] {
                note("marketing: MISSING \(n): Apple Intelligence isn't available on this Mac (\(ai.availability.label))")
            }
            return
        }
        var tabID = ""
        run { [self] in
            MarketingServer.extraPages = ["/guide/lisbon": Self.mkAIGuide, "/reading": Self.mkAIReading, "/harbour": Self.mkAIHarbour,
                                          "/trip": Self.mkAITrip]
            MarketingServer.extraFiles = ["/ai/files/IMG_2041 (1).pdf": ("application/pdf", Self.itineraryPDF())]
            LinkPreviewFeature.trustSynthetic = true
            LinkPreviewFeature.input = { [weak self] in
                var mouse = NSPoint.zero
                if let self, let v = self.c.shownTabID.flatMap({ self.c.engineTab(for: $0) })?.view, let w = v.window {
                    let r = w.convertToScreen(v.convert(v.bounds, to: nil))
                    mouse = NSPoint(x: r.midX, y: r.midY)
                }
                return (true, false, mouse)
            }
            if let s = app?.settings {
                ai.setAskPage(true, settings: s)
                ai.setLinkPreviews(true, settings: s)
                ai.setTidyDownloads(true, settings: s)
            }
        }

        // 1. Ask on Page.
        mkShow(d, "travel", nil)
        run { [self] in
            tabID = (try? c.store.openTab(url: MarketingDemo.site("travel", "/guide/lisbon"), inSpace: c.currentSpaceID,
                                          title: "Lisbon in three days"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(tabID, focus: false)
        }
        mkSettleShown()
        run { [self] in c.showAsk(question: "When is the castle open?") }
        step { [self] done in
            waitUntil({ AskPageFeature.session(of: self.c)?.run?.state.isFinished == true }, timeout: 45) { done() }
        }
        run { [self] in
            let s = AskPageFeature.session(of: c)?.run?.state
            note("marketing: ask answer (\(String(describing: s?.phase))): \(s?.answer ?? "none") quotes \(s?.quotes.map(\.text) ?? [])")
            AskPageFeature.session(of: c)?.card.quoteRows.first?.action?()
            // The question as typed, not selected.
            c.window.makeFirstResponder(nil)
        }
        wait(1.4)
        mkWindowShot("ai-ask-page") { [self] frame in
            guard let bar = c.findBar, let card = AskPageFeature.session(of: c)?.card, card.hasContent else {
                note("marketing: MISSING ai-ask-page: no answer card")
                return []
            }
            return [mkAILayer(bar, frame: frame, rect: bar.bounds, radius: 10),
                    mkAILayer(card, frame: frame, rect: card.cardRect, radius: AircRadius.popover)].compactMap { $0 }
        }
        run { [self] in
            c.closeFind(refocusPage: false)
            if !tabID.isEmpty { c.closeTab(tabID) }
        }

        // 2. A link preview.
        run { [self] in
            tabID = (try? c.store.openTab(url: MarketingDemo.site("news", "/reading"), inSpace: c.currentSpaceID,
                                          title: "Weekend reading"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(tabID, focus: false)
        }
        mkSettleShown()
        run { [self] in
            c.engineTab(for: tabID)?.evaluate("""
                (function () { var a = document.getElementById('harbour'), r = a.getBoundingClientRect();
                  a.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, shiftKey: true, clientX: r.left + 8, clientY: r.top + 6, view: window }));
                  return true; })()
                """, completion: nil)
        }
        step { done in
            self.waitUntil({ if case .ready? = LinkPreviewFeature.shared.card?.state { return true } else { return LinkPreviewFeature.shared.card?.state.isFinished == true } },
                           timeout: 45) { done() }
        }
        run { [self] in note("marketing: link preview \(String(describing: LinkPreviewFeature.shared.card?.state))") }
        wait(0.6)
        mkWindowShot("ai-link-preview") { [self] frame in
            guard let card = LinkPreviewFeature.shared.card else {
                note("marketing: MISSING ai-link-preview: no card")
                return []
            }
            return [mkAILayer(card, frame: frame, rect: card.cardRect, radius: AircRadius.popover)].compactMap { $0 }
        }
        run { [self] in
            LinkPreviewFeature.shared.hide(animated: false)
            if !tabID.isEmpty { c.closeTab(tabID) }
        }

        // 3. Tidy Downloads: in Work, whose downloads go to the run's scratch folder (mkSeed), its fresh profile's
        // "Sign in to Google" card put away.
        mkShow(d, "work", nil)
        run { [self] in
            if !d.work.isEmpty, app?.settings.values.dismissedSignIn.contains(d.work) == false { app?.settings.values.dismissedSignIn.append(d.work) }
            tabID = (try? c.store.openTab(url: MarketingDemo.site("travel", "/trip"), inSpace: c.currentSpaceID,
                                          title: "Your trip to Lisbon"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(tabID, focus: false)
        }
        mkSettleShown()
        run { [self] in c.engineTab(for: tabID)?.evaluate("location.href = '/ai/files/IMG_2041%20(1).pdf'; true", completion: nil) }
        step { done in
            self.waitUntil({
                MediaLibrary.shared.downloads?.items.contains { TidyDownloadsFeature.suggestion(for: $0) != nil } == true
            }, timeout: 45) { done() }
        }
        run { [self] in
            let item = MediaLibrary.shared.downloads?.items.first { $0.download.fileName.hasPrefix("IMG_2041") }
            note("marketing: tidy suggestion for \(item?.download.fileName ?? "no download"): \(item.flatMap(TidyDownloadsFeature.suggestion) ?? "none")")
            c.showLibrary(.downloads)
        }
        // The Library slides in on the display link: it stalls while the screen is locked.
        wait(2.5)
        run { [self] in if Self.screenLocked { note("marketing: ai-tidy-downloads taken with the screen locked: the Library may not have slid in") } }
        mkWindowShot("ai-tidy-downloads")
        run { [self] in
            c.showLibrary()   // toggles it closed
            if !tabID.isEmpty { c.closeTab(tabID) }
        }

        // 4. Settings → AI, every feature on (Tidy tab titles last, so it renames no row in the shots above).
        run { [self] in
            if let s = app?.settings { ai.setTidyTitles(true, settings: s) }
            NSApp.appearance = NSAppearance(named: .aqua)
            c.app?.showSettings(page: .ai)
            // Tall enough for every section.
            if let w = c.app?.settingsWindow?.window {
                w.setContentSize(NSSize(width: w.contentRect(forFrameRect: w.frame).width, height: 1180))
                w.setFrameOrigin(NSPoint(x: -6000, y: 100))
            }
        }
        wait(0.9)
        step { [self] done in
            defer { done() }
            guard let w = c.app?.settingsWindow?.window, let view = w.contentView, let img = mkContentImage(w) else {
                return note("marketing: MISSING ai-settings: no Settings window")
            }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("ai-settings", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w)),
            ])
        }
        run {
            LinkPreviewFeature.trustSynthetic = false
            MarketingServer.extraPages = [:]
            MarketingServer.extraFiles = [:]
        }
    }

    /// One of our views drawn over the window shot at its place (the shot's page picture covers anything over the page
    /// card): `rect` of the view (its card, without the shadow's room), with a panel's corners and shadow.
    func mkAILayer(_ v: NSView, frame: NSRect, rect: NSRect, radius: CGFloat) -> MarketingStudio.Layer? {
        guard v.window === c.window, let full = render(v) else { return nil }
        let size = v.bounds.size
        let crop = NSImage(size: rect.size)
        crop.lockFocus()
        // The image's own coordinates are bottom-up; a flipped view's rect counts from the top.
        let y = v.isFlipped ? size.height - rect.maxY : rect.minY
        full.draw(in: NSRect(x: -rect.minX, y: -y, width: size.width, height: size.height))
        crop.unlockFocus()
        let r = v.convert(rect, to: nil)
        return MarketingStudio.Layer(image: crop, frame: NSRect(x: frame.minX + r.minX, y: frame.minY + r.minY, width: r.width, height: r.height),
                                     radius: radius, dark: mkIsDark(), shadow: .panel)
    }
}
#endif
