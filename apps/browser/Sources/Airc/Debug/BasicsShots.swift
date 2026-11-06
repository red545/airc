// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Marketing shots of private windows (PW-1) and Manage Spaces (SB-21), the marketing scenario's part "basics"
/// (`scripts/marketing-shots.sh --parts basics`):
///   - private-window: a private window on Wikipedia's Private browsing article, with two more tabs;
///   - private-window-start: a new private window, before its first tab;
///   - manage-spaces: the demo's four Spaces in Manage Spaces over the Personal Space.
/// The private windows sit off screen like the main window; nothing they load is kept.
extension SnapshotRunner {
    func mkBasicsShots(_ d: MarketingDemo) {
        var w: PrivateWindowController?
        let size = NSSize(width: 1440, height: 900)
        mkShow(d, "personal", "apple")
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { p in
                w = p
                if let p {
                    p.window.setFrame(NSRect(origin: NSPoint(x: c.window.frame.minX + 40, y: c.window.frame.minY - 40), size: size), display: true)
                }
                done()
            }
        }
        wait(0.6)
        mkPrivateShot({ w }, "private-window-start")
        run {
            guard let p = w else { return }
            for url in ["https://duckduckgo.com/", "https://en.wikipedia.org/wiki/HTTP_cookie", "https://en.wikipedia.org/wiki/Private_browsing"] {
                p.openPage(URL(string: url))
            }
        }
        mkSettle({ w?.pages.map(\.tab) ?? [] }, timeout: 20, extra: 1.5)
        mkPrivateShot({ w }, "private-window")
        run { w?.closeWindow() }
        wait(0.6)

        mkShow(d, "personal", "apple")
        mkSettleShown(timeout: 10, extra: 0.6)
        run { [self] in c.showManageSpaces() }
        wait(1.0)
        mkWindowShot("manage-spaces")
        run { [self] in c.closeManageSpaces() }
        wait(0.3)
    }

    /// A private window alone on a dark desktop.
    private func mkPrivateShot(_ w: @escaping () -> PrivateWindowController?, _ name: String) {
        step { [self] done in
            guard let p = w() else { note("marketing: MISSING \(name): no private window"); return done() }
            mkActiveLook(p.window)
            privateWindowImage(p) { img in
                guard let img else { self.note("marketing: MISSING \(name): no capture"); return done() }
                let size = p.root.bounds.size
                let (canvas, origin) = MarketingStudio.canvas(around: size)
                self.mkWrite(name, canvas: canvas, dark: true, [
                    MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: size), dark: true, lights: self.mkLights(p.window)),
                ])
                done()
            }
        }
    }
}
#endif
