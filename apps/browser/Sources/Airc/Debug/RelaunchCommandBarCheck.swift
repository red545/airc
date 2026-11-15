// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit

/// After a relaunch with restored tabs, no Command Bar over the page (polish4). Arc opens it on launch only into an
/// empty window; a restored session shows its pages. Two ways it could show: opened (`commandBar`), or the spare bar
/// kept parked for ⌘T back on screen, which AppKit did once its layer joined the window (CommandBarLayer): the
/// relaunch onto a note in a split kept it over the page. Waits for the spare bar (made at idle, a quarter second
/// after the window) and a display cycle after it, then checks every browser window. Used by the relaunch halves of
/// split-read, notes-read, windows-read and parityp13b-relaunch.
extension SnapshotRunner {
    func checkNoCommandBarAfterRelaunch(_ label: String) {
        step { [self] done in
            waitUntil({ (self.app?.controllers ?? []).allSatisfy { $0.spareCommandBar != nil || $0.commandBar != nil } }, timeout: 4) {
                // The display cycle that used to put the parked bar back on screen, and one more.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
            }
        }
        run { [self] in
            for (i, w) in (app?.controllers ?? []).enumerated() {
                let which = (app?.controllers.count ?? 0) > 1 ? " (window \(i + 1))" : ""
                let spare = w.spareCommandBar
                // Where the window server draws the parked bar: its layer's left edge with the park offset applied
                // (`frame` is undefined under a transform).
                let x = (spare?.layer?.presentation() ?? spare?.layer).map { $0.position.x - $0.bounds.width * $0.anchorPoint.x + $0.transform.m41 } ?? 0
                let offScreen = spare.map { $0.isParked && x + $0.bounds.width <= 0 } ?? true
                check(w.commandBar == nil && offScreen,
                      "\(label): after the relaunch no Command Bar is over the page\(which) (open: \(w.commandBar.map { "\($0.mode)" } ?? "none"), "
                      + "spare: \(spare.map { $0.isParked ? "parked at x \(Int(x))" : "not parked" } ?? "not made"))")
            }
        }
    }
}
#endif
