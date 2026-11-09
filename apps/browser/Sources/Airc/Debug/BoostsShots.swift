// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Boosts' marketing shots (BST-1), through the marketing scenario's hook for features in other files
/// (MarketingScenario.swift, `MarketingExtraShots`): `AIRC_MARKETING_PART=boosts`, or `scripts/marketing-shots.sh
/// --parts boosts`. Wikipedia's Typography article in the demo's Personal Space, boosted into a warm, bookish page
/// (a soft amber tint and Charter, the Appearance column zapped), with the Boost editor open on Colors, then on Font
/// and Zap; then (BST-3) its share sheet with the page's screenshot, the gallery's Night Wikipedia under review with
/// Try It On (the page behind the sheet already dark), and the gallery window. The Boosts are removed afterwards.
extension SnapshotRunner: MarketingExtraShots {
    func marketingExtraShots(part: String, demo d: MarketingDemo) {
        if part == "themes" { return mkThemeShots(d) }   // ThemeShots.swift (P07)
        guard part == "boosts" else { return }
        mkShow(d, "personal", "natoday")
        mkSettleShown(timeout: 15, extra: 0.8)
        run { [self] in
            BoostCenter.shared?.update(domain: "wikipedia.org") {
                $0.colors = BoostColors(hue: 0.09, tint: 0.38, brightness: 1, contrast: 1.04, invert: false)
                $0.font = BoostFont(family: .charter, size: 1)
                $0.zaps = [BoostZap(selector: ".vector-column-end", label: "Appearance")]
            }
            c.showBoostEditor(section: .colors)
        }
        wait(1.2)
        mkWindowShot("boosts")
        run { [self] in c.boostEditor?.model.section = .font }
        wait(0.8)
        mkWindowShot("boosts-font")
        run { [self] in c.boostEditor?.model.section = .zap }
        wait(0.8)
        mkWindowShot("boosts-zap")
        run { [self] in
            c.closeBoostEditor(animated: false)
            BoostCenter.shared?.store.rename(domain: "wikipedia.org", to: "Bookish Wikipedia")
            guard let center = BoostCenter.shared, let share = BoostShareSheet(domain: "wikipedia.org", parent: c.window, controller: c, center: center)
            else { return note("marketing: MISSING boosts-share: no share sheet") }
            share.author = "Robin"
            share.about = "A warm paper tint and Charter, for long reads."
            share.present()
        }
        step { [self] done in
            waitUntil({ BoostShareSheet.active[ObjectIdentifier(self.c.window)]?.screenshot != nil }, timeout: 5) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
        }
        mkBoostSheetShot("boosts-share")
        run { [self] in
            BoostShareSheet.active[ObjectIdentifier(c.window)]?.close()
            BoostCenter.shared?.remove(domain: "wikipedia.org", page: nil)
            guard let center = BoostCenter.shared, let night = BoostGallery.entries.first(where: { $0.file.name == "Night Wikipedia" }) else { return }
            let review = BoostImportReview(file: night.file, source: .gallery(night), parent: c.window, controller: c, center: center)
            review.present()
            review.setTryOn(true)
        }
        wait(2)
        mkBoostSheetShot("boosts-review")
        run { [self] in
            BoostImportReview.active[ObjectIdentifier(c.window)]?.cancel()
            if let app { BoostGalleryWindow.show(app: app) }
        }
        wait(1.2)
        step { [self] done in
            defer { done() }
            guard let w = BoostGalleryWindow.shared?.window, let img = mkContentImage(w) else { return note("marketing: MISSING boosts-gallery") }
            let (canvas, origin) = MarketingStudio.canvas(around: w.contentView?.bounds.size ?? w.frame.size)
            mkWrite("boosts-gallery", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: w.contentView?.bounds.size ?? w.frame.size), lights: mkLights(w)),
            ])
        }
        run { BoostGalleryWindow.shared?.window.close() }
    }

    /// The browser window with the sheet on it, as macOS draws a sheet: at the window's top, centred, with its shadow.
    private func mkBoostSheetShot(_ name: String) {
        step { [self] done in
            guard let sheet = c.window.attachedSheet, let card = mkContentImage(sheet) else {
                note("marketing: MISSING \(name): no sheet"); return done()
            }
            let sf = sheet.frame, wf = c.window.frame
            mkWindowImage { img in
                guard let img else { self.note("marketing: MISSING \(name): no capture"); return done() }
                let size = self.c.root.bounds.size
                let (canvas, origin) = MarketingStudio.canvas(around: size)
                let frame = NSRect(origin: origin, size: size)
                self.mkWrite(name, canvas: canvas, dark: false, [
                    MarketingStudio.Layer(image: img, frame: frame, dark: self.mkIsDark(), lights: self.mkLights(self.c.window)),
                    MarketingStudio.Layer(image: card, frame: NSRect(x: frame.minX + sf.minX - wf.minX, y: frame.minY + sf.minY - wf.minY,
                                                                     width: sf.width, height: sf.height), radius: 16, shadow: .panel),
                ])
                done()
            }
        }
    }
}
#endif
