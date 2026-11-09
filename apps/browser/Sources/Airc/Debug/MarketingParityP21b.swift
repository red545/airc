// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The marketing shots of P21b, the marketing scenario's part "parityp21b" (`scripts/marketing-shots.sh --parts
/// parityp21b`), on a fake ready update (nothing installs):
///   - update-whats-new: Personal on apple.com, the update pill's menu open with See What's New under the pointer.
///   - update-playing: the question a restart asks while music plays in another tab, with See What's New.
///   - settings-app-icon: Settings › Appearance at its end: App Icon (Holographic, Outline).
extension SnapshotRunner {
    func mkParityP21bShots(_ d: MarketingDemo) {
        let fake = FakeReadyUpdate(version: "1.1 (202611200100)")
        mkShow(d, "personal", "apple")
        mkSettleShown()
        mkCloseAppleRegionBanner(d)
        run { UpdateCenter.shared.setReady(fake) }
        wait(0.6)
        mkWindowShot("update-whats-new") { [self] frame in
            let b = c.sidebar.update
            guard b.isShowing, let image = Self.mkMenuImage(b.pillMenu(), highlighted: UpdateConfirmModel.whatsNewTitle, dark: mkIsDark()) else {
                note("marketing: MISSING update-whats-new: no pill")
                return []
            }
            // Right-clicked at the pill's restart glyph: the menu opens there, clear of the pill's title.
            let r = b.convert(b.pillRect, to: nil)
            let at = NSPoint(x: frame.minX + r.maxX - 22, y: frame.minY + r.midY + 4)
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: at.x, y: at.y - image.size.height, width: image.size.width,
                                                                      height: image.size.height),
                                          radius: Self.mkMenuRadius, dark: mkIsDark(), shadow: .panel)]
        }
        // The question, as the real probe would find music playing in another tab.
        run {
            UpdateCenter.shared.riskProbe = { _, done in var r = UpdateRestartRisks(); r.playing = true; done(r) }
            UpdateCenter.shared.restart(from: self.c)
        }
        wait(0.6)
        mkWindowShot("update-playing") { [self] frame in
            guard let v = UpdateCenter.shared.confirm, let image = render(v) else {
                note("marketing: MISSING update-playing: no question")
                return []
            }
            let r = v.convert(v.bounds, to: nil)
            return [MarketingStudio.Layer(image: image, frame: NSRect(x: frame.minX + r.minX, y: frame.minY + r.minY, width: r.width, height: r.height),
                                          radius: AircRadius.popover, dark: mkIsDark(), shadow: .panel)]
        }
        run {
            UpdateCenter.shared.confirm?.model.onAnswer?(false)
            UpdateCenter.shared.riskProbe = nil
            UpdateCenter.shared.setReady(nil)
        }
        wait(0.4)
        // Settings › Appearance, scrolled to its end, off screen like the other Settings shots.
        run { [self] in
            NSApp.appearance = NSAppearance(named: .aqua)
            c.app?.showSettings(page: .appearance)
            c.app?.settingsWindow?.window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        }
        wait(0.9)
        run { [self] in
            guard let view = c.app?.settingsWindow?.window.contentView else { return }
            for s in Self.mkScrollViews(in: view) {
                guard let doc = s.documentView else { continue }
                let end = NSPoint(x: 0, y: doc.isFlipped ? max(0, doc.bounds.height - s.contentView.bounds.height) : 0)
                s.contentView.scroll(to: end)
                s.reflectScrolledClipView(s.contentView)
            }
        }
        wait(0.5)
        step { [self] done in
            defer { done() }
            guard let w = c.app?.settingsWindow?.window, let view = w.contentView, let img = mkContentImage(w) else {
                return note("marketing: MISSING settings-app-icon: no Settings window")
            }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("settings-app-icon", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w)),
            ])
            w.orderOut(nil)
        }
    }

    /// apple.com's "choose another country or region" banner (its locale switcher, shown by the Mac's country): closed
    /// with its own close button, as a person would, and the shots wait until it's gone. If it won't go, the run says
    /// so (MISSING) and the shots are retaken.
    private func mkCloseAppleRegionBanner(_ d: MarketingDemo) {
        let shown = "(function(){var e=document.getElementById('ac-localeswitcher');return !!e&&e.offsetHeight>0})()"
        var gone = false
        step { [self] done in
            guard let page = c.engineTab(for: d.tab["apple"] ?? "") else { return done() }
            page.evaluate("(function(){var b=document.getElementById('ac-ls-close');if(b)b.click();return !!b})()") { _ in
                var tries = 0
                func poll() {
                    page.evaluate(shown) { v in
                        if (v as? Bool) != true { gone = true; return done() }
                        tries += 1
                        guard tries < 20 else { return done() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                    }
                }
                poll()
            }
        }
        wait(0.8)
        run { [self] in
            if !gone { note("marketing: MISSING update-whats-new, update-playing: apple.com's region banner didn't close") }
        }
    }

    /// The page's scroll views (the Settings page's own, not its sidebar's: the taller document).
    private static func mkScrollViews(in view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { out.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        let tallest = out.max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
        return tallest.map { [$0] } ?? []
    }
}
#endif
