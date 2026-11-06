// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Tab previews' marketing shots (SB-45), the marketing scenario's part "previews" (`scripts/marketing-shots.sh --parts
/// previews`):
///   - tab-preview: Personal on apple.com, the pointer resting on the Kyoto tab (Wikivoyage), whose card shows the page
///     as it was left, with its quick actions;
///   - tab-preview-dark: Work in dark mode on linear.app, the card of the swiftlang/swift tab (GitHub).
/// Each previewed page is shown first and pictured as the app does, then another page comes on screen; the pointer is
/// the row's own hover handler (no cursor in the shot, as in every other one).
extension SnapshotRunner {
    func mkPreviewShots(_ d: MarketingDemo) {
        mkPreviewShot(d, space: "personal", previewed: "kyoto", shown: "apple", name: "tab-preview", dark: false)
        mkPreviewShot(d, space: "work", previewed: "github", shown: "linear", name: "tab-preview-dark", dark: true)
    }

    private func mkPreviewShot(_ d: MarketingDemo, space: String, previewed: String, shown: String, name: String, dark: Bool) {
        if dark { run { NSApp.appearance = NSAppearance(named: .darkAqua) } }
        mkShow(d, space, previewed)
        mkSettleShown(timeout: 15, extra: 1.6)
        step { [self] done in
            guard let id = d.tab[previewed] else { return done() }
            c.tabPreview.capture(id, reason: .shown) { image in
                if image == nil { self.note("marketing: \(name): no picture of \(previewed) yet") }
                done()
            }
        }
        mkShow(d, space, shown)
        mkSettleShown(timeout: 15, extra: 1.0)
        run { [self] in
            guard let id = d.tab[previewed], let page = c.pageView(for: c.currentSpaceID) else { return }
            page.layoutSubtreeIfNeeded()
            guard let row = page.list.subviews.compactMap({ $0 as? TabRowView }).first(where: { $0.tabID == id }) else {
                return note("marketing: MISSING \(name): no row for \(previewed)")
            }
            // A pointer resting near the row's start, where it is after moving down the list.
            let p = row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
            if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                row.mouseEntered(with: e)
            }
        }
        wait(TabPreviewController.dwell + 0.9)
        run { [self] in
            if !c.tabPreview.isShowing { note("marketing: MISSING \(name): the card didn't show") }
            if c.tabPreview.thumbnail != .cached { note("marketing: \(name): the card shows \(c.tabPreview.thumbnail.rawValue)") }
        }
        mkWindowShot(name, dark: dark)
        run { [self] in
            guard let row = c.tabPreview.shownRow else { return c.tabPreview.hide() }
            c.tabPreview.hoverEnded(row, event: nil)
            c.tabPreview.hide()
            if dark { NSApp.appearance = NSAppearance(named: .aqua) }
        }
        wait(0.3)
    }
}
#endif
