// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// `--script updatedtoast`: "Updated!" after an update's restart, as the owner saw it in 0.1.4 (top-left, gone at once).
/// Right at launch, at a window size other than the default, a stale LastVersion takes the real path
/// (`noteLaunchedVersion`). Then: the toast is centred `Toast.topInset` below the page card's top (within 1 pt), and
/// drawn where its frame is; it stays centred after a window resize and the sidebar hiding and showing; it is still up
/// at 5 s and past its time while the pointer rests on it, and goes after the pointer leaves; unhovered, it is up at
/// 5 s and gone after `UpdatedToastView.duration`; Esc and See What's New hide it.
extension SnapshotRunner {
    func updatedToastScenario() {
        var shownAt = Date()
        func t() -> UpdatedToastView? { c.updatedToast }
        func label() -> String { "card \(fmt(c.card.frame)), toast \(t().map { fmt($0.frame) } ?? "-")" }
        func fmt(_ r: NSRect) -> String { String(format: "(%.1f, %.1f, %.1f×%.1f)", r.minX, r.minY, r.width, r.height) }
        /// Centred on the card's top within 1 pt, and drawn there (the layer's on-screen rect is its frame).
        func centred() -> (Bool, String) {
            guard let v = t(), !v.isHidden else { return (false, "no toast") }
            let card = c.card.frame
            let dx = v.frame.midX - card.midX, dy = v.frame.minY - (card.minY + AircMetrics.Toast.topInset)
            // Where it's drawn: its layer's rect in window coordinates, against its frame in window coordinates.
            var drawnOK = true, drawnText = ""
            if let layer = v.layer, let rootLayer = c.root.layer {
                let model = layer.convert(layer.bounds, to: rootLayer)
                let viaView = c.root.convert(v.frame, to: nil)
                // The root layer's coordinates are the root view's when it's flipped (AppKit), else bottom-up.
                let asView = rootLayer.contentsAreFlipped() || rootLayer.isGeometryFlipped
                    ? model : NSRect(x: model.minX, y: c.root.bounds.height - model.maxY, width: model.width, height: model.height)
                let drawn = c.root.convert(asView, to: nil)
                drawnOK = abs(drawn.midX - viaView.midX) <= 1 && abs(drawn.midY - viaView.midY) <= 1
                drawnText = ", drawn \(fmt(drawn)) vs frame \(fmt(viaView))"
            }
            return (abs(dx) <= 1 && abs(dy) <= 1 && drawnOK, String(format: "dx %.2f, dy %.2f", dx, dy) + drawnText + "; " + label())
        }
        func hover(_ inside: Bool) {
            guard let v = t(), let e = NSEvent.enterExitEvent(with: inside ? .mouseEntered : .mouseExited, location: .zero,
                                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0,
                                                              trackingNumber: 0, userData: nil) else { return }
            if inside { v.mouseEntered(with: e) } else { v.mouseExited(with: e) }
        }
        func waitShown(_ name: String) {
            step { [self] done in
                waitUntil({ self.c.updatedToast?.shownText != nil }, timeout: 15) {
                    shownAt = Date()
                    self.check(self.c.updatedToast?.shownText == UpdateCenter.updatedMessage(UpdateCenter.runningVersion),
                               "updatedtoast: \(name): “\(self.c.updatedToast?.shownText ?? "no toast")”")
                    done()
                }
            }
        }
        /// Waits until `seconds` after the toast came.
        func until(_ seconds: Double) {
            step { done in
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds - Date().timeIntervalSince(shownAt)), execute: done)
            }
        }
        let notes = ParityCommandCatalog.releaseNotes

        // 1. Right at launch, at a non-default size: the real launch path with a stale LastVersion.
        run { [self] in
            let v = c.window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            c.window.setFrame(NSRect(x: v.minX + 30, y: v.maxY - 700, width: 1030, height: 700), display: false)
            try? Data("0.0.1 (1)".utf8).write(to: UpdateCenter.lastVersionFile)
            note("updatedtoast: at launch: window \(fmt(c.window.frame)), \(label())")
            UpdateCenter.shared.noteLaunchedVersion(inScriptedRun: true)
        }
        waitShown("Updated! shows after launch")
        wait(0.8)   // the pop spring settles
        run { [self] in
            let (ok, why) = centred()
            check(ok, "updatedtoast: after launch at 1030×700 it's centred at the top of the page card (\(why))")
        }
        capture("updatedtoast-launch")

        // 2. Window resize, then the sidebar hiding and showing.
        run { [self] in
            let f = c.window.frame
            c.window.setFrame(NSRect(x: f.minX, y: f.maxY - 860, width: 1340, height: 860), display: true)
        }
        wait(0.3)
        run { [self] in
            let (ok, why) = centred()
            check(ok, "updatedtoast: after resizing the window to 1340×860 it's still centred (\(why))")
            hover(true)   // from here the pointer rests on it
        }
        run { [self] in c.toggleSidebar() }
        wait(max(AircCurve.sidebarHide.duration, AircCurve.sidebarShow.duration) + 0.3)
        run { [self] in
            let (ok, why) = centred()
            check(ok && c.sidebarHidden, "updatedtoast: with the sidebar hidden it's centred on the wider card (\(why))")
        }
        capture("updatedtoast-sidebar-hidden")
        run { [self] in c.toggleSidebar() }
        wait(max(AircCurve.sidebarHide.duration, AircCurve.sidebarShow.duration) + 0.3)
        run { [self] in
            let (ok, why) = centred()
            check(ok && !c.sidebarHidden, "updatedtoast: with the sidebar back it's centred again (\(why))")
        }

        // 3. Hovered: still up at 5 s and past its time; goes after the pointer leaves.
        until(5)
        run { [self] in
            check(t()?.shownText != nil && t()?.isHovered == true, "updatedtoast: hovered, still up at 5 s")
        }
        until(UpdatedToastView.duration + 1.5)
        run { [self] in
            check(t()?.shownText != nil, "updatedtoast: hovered, still up past its \(UpdatedToastView.duration) s")
            hover(false)
        }
        step { [self] done in waitUntil({ self.c.updatedToast?.shownText == nil }, timeout: UpdatedToastView.afterHover + 2) { done() } }
        run { [self] in check(t()?.shownText == nil, "updatedtoast: goes once the pointer leaves it") }
        wait(0.5)

        // 4. Unhovered: up at 5 s, gone after its time.
        run { [self] in c.showUpdatedToast(UpdateCenter.updatedMessage(UpdateCenter.runningVersion), notes: notes) }
        waitShown("shown again, nothing over it")
        until(5)
        run { [self] in check(t()?.shownText != nil, "updatedtoast: unhovered, still up at 5 s") }
        step { [self] done in waitUntil({ self.c.updatedToast?.shownText == nil }, timeout: UpdatedToastView.duration + 3) { done() } }
        run { [self] in
            let at = Date().timeIntervalSince(shownAt)
            check(t()?.shownText == nil && at >= UpdatedToastView.duration - 0.2 && at < UpdatedToastView.duration + 2.5,
                  String(format: "updatedtoast: unhovered, it goes by itself after %.1f s (want %.0f s)", at, UpdatedToastView.duration))
        }
        wait(0.5)

        // 5. Esc hides it (through the app's key monitor).
        run { [self] in c.showUpdatedToast(UpdateCenter.updatedMessage(UpdateCenter.runningVersion), notes: notes) }
        waitShown("shown for Esc")
        wait(0.4)
        run { [self] in Self.postEscape(to: c.window) }
        step { [self] done in waitUntil({ self.c.updatedToast?.shownText == nil }, timeout: 1.5) { done() } }
        run { [self] in check(t()?.shownText == nil, "updatedtoast: Esc hides it") }
        wait(0.5)

        // 6. See What's New hides it and asks for the notes.
        var opened: URL?
        run { [self] in
            c.showUpdatedToast(UpdateCenter.updatedMessage(UpdateCenter.runningVersion), notes: notes)
            t()?.onWhatsNew = { opened = $0 }
        }
        waitShown("shown for See What's New")
        wait(0.4)
        run { [self] in t()?.button.performClick(nil) }
        step { [self] done in waitUntil({ self.c.updatedToast?.shownText == nil }, timeout: 1.5) { done() } }
        run { [self] in
            check(t()?.shownText == nil && opened == notes, "updatedtoast: See What's New hides it and opens \(opened?.absoluteString ?? "nothing")")
        }
        wait(0.5)
        run { [self] in try? FileManager.default.removeItem(at: UpdateCenter.lastVersionFile) }
    }
}
#endif
