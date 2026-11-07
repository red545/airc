// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of several windows (WIN-7), the marketing scenario's part "windows"
/// (`scripts/marketing-shots.sh --parts windows`):
///   - multiple-windows: two windows of the demo on different Spaces, each with its own tab: Travel on the Lisbon
///     article in front, Work on linear.app behind it (the window behind drawn as macOS draws an inactive one).
/// Both windows sit off screen; the second one closes afterwards.
extension SnapshotRunner {
    func mkWindowsShots(_ d: MarketingDemo) {
        var back: WindowController?
        let size = NSSize(width: 1280, height: 800)
        step { [self] done in
            guard let app, let work = d.space["work"] else { return done() }
            let front = c!
            back = app.openNewWindow(from: front, spaceID: work, tab: .spaceLast, commandBar: false)
            for w in [front, back].compactMap({ $0 }) {
                w.applyTranslucency(.off)
                w.window.setFrame(NSRect(origin: NSPoint(x: front.window.frame.minX, y: front.window.frame.minY), size: size), display: true)
            }
            if let t = d.tab["linear"] { back?.show(t, focus: false) }
            app.browserWindowBecameKey(front)
            done()
        }
        mkShow(d, "travel", "lisbon")
        mkSettle({ [self] in [c.shownTabID.flatMap { c.engineTab(for: $0) }, back?.shownTabID.flatMap { back?.engineTab(for: $0) }] },
                 timeout: 20, extra: 1.5)
        step { [self] done in
            guard let app, let behind = back else { note("marketing: MISSING multiple-windows: no second window"); return done() }
            let front = c!
            // Each window drawn as the runner's window in turn (captureNow draws app.controller).
            app.browserWindowBecameKey(behind)
            mkWindowImage { backImage in
                app.browserWindowBecameKey(front)
                self.mkWindowImage { frontImage in
                    guard let backImage, let frontImage else { self.note("marketing: MISSING multiple-windows: no capture"); return done() }
                    // The window behind up and to the left, the front one down and to the right, overlapping.
                    let shift = NSSize(width: 420, height: 230)
                    let (canvas, origin) = MarketingStudio.canvas(around: NSSize(width: size.width + shift.width, height: size.height + shift.height))
                    let backFrame = NSRect(origin: NSPoint(x: origin.x, y: origin.y + shift.height), size: size)
                    let frontFrame = NSRect(origin: NSPoint(x: origin.x + shift.width, y: origin.y), size: size)
                    let isDark = { (w: WindowController) in w.palette(for: w.store.space(w.currentSpaceID) ?? w.store.selectedSpace).isDark }
                    self.mkWrite("multiple-windows", canvas: canvas, dark: false, [
                        MarketingStudio.Layer(image: backImage, frame: backFrame, dark: isDark(behind)),
                        MarketingStudio.Layer(image: frontImage, frame: frontFrame, dark: isDark(front), lights: self.mkLights(front.window)),
                    ])
                    done()
                }
            }
        }
        run { back?.window.performClose(nil) }
        wait(0.5)
    }
}
#endif
