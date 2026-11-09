// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    func mkRoutingShots(_ demo: MarketingDemo) {
        run { [self] in
            if let studio = demo.space["studio"] {
                c.app?.settings.values.linkRules = [LinkRule(pattern: "figma.com", spaceID: studio)]
            }
            c.app?.showSettings(page: .links)
            c.app?.settingsWindow?.window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        }
        wait(0.9)
        run { [self] in
            guard let window = c.app?.settingsWindow?.window, let view = window.contentView,
                  let image = mkContentImage(window) else { return note("marketing: MISSING settings-links: no Settings window") }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite("settings-links", canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: image, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(window))
            ])
            window.orderOut(nil)
        }
    }
}
#endif
