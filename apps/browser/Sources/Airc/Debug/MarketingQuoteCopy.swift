// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The marketing shots of Arc's quote links (C06), the marketing scenario's part "quotecopy"
/// (`scripts/marketing-shots.sh --parts quotecopy`):
///   - quote-copy: a made-up article of our own ("Reading type at a distance", Field Notes, MarketingServer's
///     journal.aircbrowser.com/typography; no third-party site, so no rate limit can break it) with a sentence
///     selected, Share Quote in the address pill, and Arc's toast "Copied Link" · "With Quote" after a click on it.
///   - quote-copy-dark: the same in a dark Space.
extension SnapshotRunner {
    /// The article the quote-copy shots select from: made-up text, our own page.
    static let mkQuoteArticle = """
    <!doctype html><meta charset="utf-8"><title>Reading type at a distance – Field Notes</title>
    <style>
    body{margin:0;background:#fbfaf7;color:#1d1d1f;font:19px/1.6 Georgia,'Times New Roman',serif}
    header{border-bottom:1px solid #e6e2da;padding:18px 0;text-align:center;font:600 15px -apple-system,sans-serif;letter-spacing:.14em;text-transform:uppercase;color:#6b6457}
    article{max-width:680px;margin:0 auto;padding:56px 32px 120px}
    h1{font:700 44px/1.15 -apple-system,sans-serif;letter-spacing:-.02em;margin:0 0 12px}
    .dek{font:21px/1.45 -apple-system,sans-serif;color:#5e5a53;margin:0 0 28px}
    .by{font:14px -apple-system,sans-serif;color:#8a8478;margin:0 0 40px}
    h2{font:700 24px -apple-system,sans-serif;margin:44px 0 10px}
    ::selection{background:#b9d7ff}
    </style>
    <header>Field Notes</header>
    <article>
    <h1>Reading type at a distance</h1>
    <p class="dek">Why signs on a platform, a menu across the room and a phone at arm's length ask different things of a typeface.</p>
    <p class="by">By the Field Notes desk · 6 min read</p>
    <p>A letter seen from far away loses its fine details long before it loses its shape. The open curves, the gaps inside an e or an a, and the space between letters are what carry it across a room, which is why the best signage faces look almost plain up close.</p>
    <p>Designers of railway signs learned this by standing at the far end of real platforms with printed samples. They widened the counters, lowered the contrast between thick and thin strokes, and gave each letter a little more air, until a word could be read in the time it takes a train to slow down.</p>
    <h2>Size is not the whole answer</h2>
    <p>Making text bigger helps only until the line no longer fits the space it was meant for. Weight, spacing and the height of the lowercase letters often do more than an extra point of size, and a calm layout with clear margins lets the eye find its place again after every glance away.</p>
    <p>The same rules hold on a small screen held at arm's length: generous spacing, honest contrast and shapes that stay distinct when they are only a few pixels tall.</p>
    </article>
    """

    func mkQuoteCopyShots(_ d: MarketingDemo) {
        var appearanceBefore: Appearance?
        var tab = ""
        run { [self] in
            MarketingServer.extraPages["/typography"] = Self.mkQuoteArticle
            guard let sid = d.space["personal"] else { return }
            tab = (try? c.store.openTab(url: MarketingDemo.site("journal", "/typography"), inSpace: sid, activate: false,
                                        title: "Reading type at a distance – Field Notes").id) ?? ""
        }
        mkShow(d, "personal", nil)
        run { [self] in if !tab.isEmpty { c.show(tab, focus: false) } }
        mkSettleShown()
        for dark in [false, true] {
            if dark {
                run { [self] in
                    appearanceBefore = c.store.space(c.currentSpaceID)?.theme.appearance
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = .dark }
                    c.reloadAll(animated: false)
                }
                wait(0.8)
            }
            // A sentence of the article selected, as a drag leaves it; the pill reads the page's selection itself.
            step { [self] done in
                guard let page = c.engineTab(for: tab) else { note("marketing: MISSING quote-copy: no page"); return done() }
                let pick = "(function(){var p=[].slice.call(document.querySelectorAll('article p')).find(function(e){"
                    + "return e.firstChild&&e.firstChild.nodeType===3&&e.firstChild.data.indexOf('. ')>60});if(!p)return '';"
                    + "var t=p.firstChild,r=document.createRange();r.setStart(t,0);r.setEnd(t,t.data.indexOf('. ')+1);"
                    + "p.scrollIntoView({block:'center'});getSelection().removeAllRanges();getSelection().addRange(r);return String(r)})()"
                page.evaluate(pick) { v in
                    if ((v as? String) ?? "").isEmpty { self.note("marketing: MISSING quote-copy: no sentence to select") }
                    self.c.quotePill?.refresh()
                    done()
                }
            }
            wait(1.0)
            run { [self] in
                guard let pill = c.quotePill, !pill.isHidden else { return note("marketing: MISSING quote-copy: no Share Quote") }
                c.toast.show(QuoteLink.copiedToast, palette: c.currentPalette, in: c.card.frame, duration: 60,
                             detail: QuoteLink.withQuote, symbol: QuoteLink.symbol)
            }
            wait(0.8)
            // The toast is drawn over the page, which the window capture lays its own snapshot of over the card: it goes
            // on as a layer of its own, where it is in the window.
            mkWindowShot(dark ? "quote-copy-dark" : "quote-copy", dark: dark) { [self] frame in
                guard !c.toast.isHidden, let image = render(c.toast) else {
                    note("marketing: MISSING quote-copy: no toast")
                    return []
                }
                let r = c.toast.convert(c.toast.bounds, to: nil)
                return [MarketingStudio.Layer(image: image, frame: NSRect(x: frame.minX + r.minX, y: frame.minY + r.minY, width: r.width, height: r.height),
                                              radius: AircRadius.toast, dark: dark, shadow: .panel)]
            }
            run { [self] in
                c.toast.dismiss()
                c.quotePill?.hide()
                c.engineTab(for: tab)?.evaluate("getSelection().removeAllRanges();true", completion: nil)
            }
            wait(0.4)
        }
        run { [self] in
            MarketingServer.extraPages["/typography"] = nil
            if !tab.isEmpty { try? c.store.closeTab(tab) }
            if let appearanceBefore { try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = appearanceBefore } }
            NSApp.appearance = nil
            c.reloadAll(animated: false)
        }
        wait(0.5)
    }
}
#endif
