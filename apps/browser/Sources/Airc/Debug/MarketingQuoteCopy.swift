// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The marketing shots of Arc's quote links (C06), the marketing scenario's part "quotecopy"
/// (`scripts/marketing-shots.sh --parts quotecopy`):
///   - quote-copy: Typography on Wikipedia with a sentence selected, Share Quote under the address, and Arc's toast
///     "Copied Link" · "With Quote" after a click on it.
///   - quote-copy-dark: the same in a dark Space.
extension SnapshotRunner {
    func mkQuoteCopyShots(_ d: MarketingDemo) {
        var appearanceBefore: Appearance?
        mkShow(d, "personal", "natoday")
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
                guard let page = c.engineTab(for: d.tab["natoday"] ?? "") else { note("marketing: MISSING quote-copy: no page"); return done() }
                let pick = "(function(){var p=[].slice.call(document.querySelectorAll('#mw-content-text p')).find(function(e){"
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
                c.engineTab(for: d.tab["natoday"] ?? "")?.evaluate("getSelection().removeAllRanges();true", completion: nil)
            }
            wait(0.4)
        }
        run { [self] in
            if let appearanceBefore { try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = appearanceBefore } }
            NSApp.appearance = nil
            c.reloadAll(animated: false)
        }
        wait(0.5)
    }
}
#endif
