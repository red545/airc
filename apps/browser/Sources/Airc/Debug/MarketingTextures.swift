// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The marketing shots of Arc's Space textures (TH-4; arctextures), the marketing scenario's part "textures"
/// (`scripts/marketing-shots.sh --parts textures`):
///   - space-textures: Personal in denim, with Edit Theme Color… open on its Grain · Sand · Denim · Tweed swatches;
///   - space-textures-dark: the dark Work Space in tweed.
/// Both Spaces get their own themes back afterwards, so later parts see the demo as it was.
extension SnapshotRunner {
    @MainActor func mkTextureShots(_ d: MarketingDemo) {
        var saved: [String: AircKit.SpaceTheme] = [:]
        func texture(_ key: String, _ t: SpaceTexture, grain: Double) {
            run { [self] in
                guard let sid = d.space[key], let theme = c.store.space(sid)?.theme else { return }
                saved[sid] = theme
                try? c.store.updateSpace(sid) { $0.theme.texture = t; $0.theme.grain = grain }
            }
        }
        texture("personal", .denim, grain: 0.9)
        mkShow(d, "personal", "apple")
        mkSettleShown()
        run { [self] in c.editTheme(d.space["personal"] ?? "") }
        wait(0.8)
        mkWindowShot("space-textures") { [self] frame in
            guard let panel = c.themePopover?.window, let full = mkContentImage(panel) else {
                note("marketing: MISSING space-textures: no theme picker")
                return []
            }
            // The panel draws the picker inset by its shadow margin; take the picker itself.
            let m = ThemePickerPanel.margin
            let inner = NSRect(x: m, y: m, width: full.size.width - 2 * m, height: full.size.height - 2 * m)
            let card = NSImage(size: inner.size, flipped: false) { _ in
                full.draw(in: NSRect(origin: .zero, size: inner.size), from: inner, operation: .copy, fraction: 1)
                return true
            }
            let pf = panel.frame.insetBy(dx: m, dy: m), wf = c.window.frame
            return [MarketingStudio.Layer(image: card, frame: NSRect(x: frame.minX + pf.minX - wf.minX, y: frame.minY + pf.minY - wf.minY,
                                                                     width: pf.width, height: pf.height), radius: 20, shadow: .panel)]
        }
        run { [self] in c.themePopover?.close() }
        texture("work", .tweed, grain: 1)
        mkShow(d, "work", "linear")
        mkSettleShown()
        mkWindowShot("space-textures-dark", dark: true)
        run { [self] in
            for (sid, theme) in saved { try? c.store.updateSpace(sid) { $0.theme = theme } }
            c.reloadAll(animated: false)
        }
        wait(0.4)
    }
}
#endif
