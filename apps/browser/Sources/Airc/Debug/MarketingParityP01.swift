// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The marketing shots of Arc's context menus (P01a), the marketing scenario's part "parityp01"
/// (`scripts/marketing-shots.sh --parts parityp01`):
///   - tab-menu: Personal on apple.com, the Kyoto tab's menu open beside its row with Share under the pointer.
///   - folder-markdown: the Recipes folder's menu with Copy All Links as Markdown under the pointer.
///   - quote-link: Typography on Wikipedia with a sentence selected and copied: "Share a link directly to this text
///     instead?" with Copy Link.
///   - essential-shortcuts: Help › Essential Keyboard Shortcuts, the window of the person's own keys.
/// The menus are drawn from the rows' own `menu(for:)`, as the multi-selection shot draws its menu (MultiSelectShots).
extension SnapshotRunner {
    func mkParityP01Shots(_ d: MarketingDemo) {
        mkShow(d, "personal", "apple")
        mkSettleShown()
        mkRowMenuShot("tab-menu", highlighted: "Share") { [self] in
            guard let id = d.tab["kyoto"], let t = c.store.tab(id) else { return nil }
            return (id, .today(t))
        }
        mkRowMenuShot("folder-markdown", highlighted: "Copy All Links as Markdown") { [self] in
            let sid = c.currentSpaceID
            guard let f = c.store.children(of: .pinned(spaceID: sid), parent: nil).first(where: { $0.kind == .folder && $0.displayTitle == "Recipes" })
            else { return nil }
            if f.isCollapsed { try? c.store.toggleFolder(f.id) }
            return (f.id, .folder(f, depth: 0))
        }
        // The offer after ⌘C on a selected sentence.
        mkShow(d, "personal", "natoday")
        mkSettleShown()
        step { [self] done in
            guard let page = c.engineTab(for: d.tab["natoday"] ?? "") else { note("marketing: MISSING quote-link: no page"); return done() }
            let pick = "(function(){var p=[].slice.call(document.querySelectorAll('#mw-content-text p')).find(function(e){return e.textContent.length>120});"
                + "if(!p)return '';var r=document.createRange();r.selectNodeContents(p);getSelection().removeAllRanges();getSelection().addRange(r);"
                + "p.scrollIntoView({block:'center'});var t=String(getSelection());return t.split('. ')[0]})()"
            page.evaluate(pick) { v in
                let sentence = (v as? String) ?? ""
                if let url = page.url?.absoluteString, let link = LinkCopyPolicy.textFragmentURL(url, selection: sentence) {
                    self.c.showQuoteLinkOffer(link)
                    self.c.quoteLinkOffer?.show(link, palette: self.c.currentPalette, in: self.c.card.frame, duration: 60)
                } else {
                    self.note("marketing: MISSING quote-link: no paragraph to select")
                }
                done()
            }
        }
        wait(0.6)
        // The offer is drawn over the page, which the window capture lays its own snapshot of over the card: it goes on
        // as a layer of its own, where it is in the window.
        mkWindowShot("quote-link") { [self] frame in
            guard let offer = c.quoteLinkOffer, !offer.isHidden, let image = render(offer) else {
                note("marketing: MISSING quote-link: no offer")
                return []
            }
            let r = offer.convert(offer.bounds, to: nil)
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: frame.minX + r.minX, y: frame.minY + r.minY, width: r.width, height: r.height),
                                          radius: AircRadius.toast, dark: mkIsDark(), shadow: .panel)]
        }
        run { [self] in c.quoteLinkOffer?.hide() }
        // Help › Essential Keyboard Shortcuts, off screen like the Settings shots.
        var shortcuts: NSWindow?
        run {
            let w = EssentialShortcutsWindow.makeWindow()
            w.setFrameOrigin(NSPoint(x: -6000, y: 200))
            w.orderFront(nil)
            shortcuts = w
        }
        wait(0.8)
        step { [self] done in
            defer { shortcuts?.orderOut(nil); done() }
            guard let w = shortcuts, let view = w.contentView, let img = mkContentImage(w) else {
                return note("marketing: MISSING essential-shortcuts: no window")
            }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("essential-shortcuts", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w)),
            ])
        }
    }

    /// A row's context menu drawn where a right-click on it opens it, the row shown as under the pointer.
    private func mkRowMenuShot(_ name: String, highlighted: String, row find: @escaping () -> (id: String, entry: SidebarEntry)?) {
        var target: (id: String, entry: SidebarEntry)?
        run { [self] in
            target = find()
            c.root.layoutSubtreeIfNeeded()
        }
        wait(0.3)
        mkWindowShot(name) { [self] frame in
            guard let target, let page = c.pageView(for: c.currentSpaceID), let row = page.rows[target.id] else {
                note("marketing: MISSING \(name): no row")
                return []
            }
            let menu = c.menu(for: target.entry)
            guard let image = Self.mkMenuImage(menu, highlighted: highlighted, dark: mkIsDark()) else { return [] }
            let r = row.convert(row.bounds, to: nil)
            let at = NSPoint(x: frame.minX + r.minX + 150, y: frame.minY + r.midY + 6)
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: at.x, y: at.y - image.size.height, width: image.size.width,
                                                                      height: image.size.height),
                                          radius: Self.mkMenuRadius, dark: mkIsDark(), shadow: .panel)]
        }
    }
}
#endif
