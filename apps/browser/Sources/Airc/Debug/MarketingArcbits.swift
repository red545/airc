// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    func mkArcbitsShots() {
        let url = MarketingDemo.site("fieldnotes", "/journal/a-quieter-web")
        run { [self] in
            if let t = try? c.store.openTab(url: url, inSpace: c.currentSpaceID) { c.reloadAll(animated: false); c.show(t.id, focus: false) }
            c.togglePageToolbar()
        }
        mkSettleShown(); wait(0.5); mkWindowShot("show-toolbar")
        run { [self] in c.openCommandBar(mode: .newTab); c.commandBar?.type("/Copy URL") }
        wait(0.3); mkWindowShot("copy-quote")
        run { [self] in
            c.closeCommandBar()
            app?.settings.values.littleArcProfiles.remember(c.store.defaultProfile.id, for: URL(string: "https://fieldnotes.example.org"))
            app?.showSettings(page: .links)
            app?.settingsWindow?.window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        }
        wait(0.9)
        run { [self] in
            guard let w = app?.settingsWindow?.window, let view = w.contentView, let image = mkContentImage(w) else {
                return note("marketing: MISSING remembered-profiles: no Settings window")
            }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("remembered-profiles", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: image, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w))
            ])
            w.orderOut(nil)
        }
    }
}
#endif
