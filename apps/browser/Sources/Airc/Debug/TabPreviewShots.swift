// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Tab previews' marketing shots (SB-45), the marketing scenario's part "previews" (`scripts/marketing-shots.sh --parts
/// previews`):
///   - tab-preview: Personal on apple.com, the pointer resting on the Kyoto tab (Wikivoyage), whose card shows the page
///     as it was left, with its quick actions;
///   - tab-preview-dark: Work in dark mode on linear.app, the card of the swiftlang/swift tab (GitHub);
///   - site-preview: Work on the SwiftUI docs, the pointer resting on the Linear Favorite: Arc's site preview, the
///     Linear pages visited in that profile, newest first, with "+" for a new issue (P11a, Previews/).
/// Each previewed page is shown first and pictured as the app does, then another page comes on screen; the pointer is
/// the row's own hover handler (no cursor in the shot, as in every other one).
extension SnapshotRunner {
    func mkPreviewShots(_ d: MarketingDemo) {
        mkPreviewShot(d, space: "personal", previewed: "kyoto", shown: "apple", name: "tab-preview", dark: false)
        mkPreviewShot(d, space: "work", previewed: "github", shown: "linear", name: "tab-preview-dark", dark: true)
        mkSitePreviewShot(d)
    }

    private func mkSitePreviewShot(_ d: MarketingDemo) {
        let name = "site-preview"
        run { [self] in
            guard let h = c.app?.history, let space = d.space["work"] else { return note("marketing: MISSING \(name): no Work Space") }
            let profile = c.store.profile(ofSpace: space).id
            let now = Date()
            // The Linear pages visited in the Work profile, at their times.
            for (url, title, minutes) in [
                ("https://linear.app/papertrail/view/release-blockers", "Release blockers", 60.0 * 26),
                ("https://linear.app/papertrail/issue/WEB-131/onboarding-flow-redesign", "WEB-131 Onboarding flow redesign", 60.0 * 5),
                ("https://linear.app/papertrail/my-issues/assigned", "My issues", 75.0),
                ("https://linear.app/papertrail/project/launch", "Launch checklist", 26.0),
                ("https://linear.app/papertrail/issue/WEB-142/sync-status-in-the-sidebar", "WEB-142 Sync status in the sidebar", 9.0),
                ("https://linear.app/papertrail/team/WEB/active", "WEB › Active issues", 0.4),
            ] as [(String, String, Double)] {
                h.now = { now.addingTimeInterval(-minutes * 60) }
                h.recordVisit(profileID: profile, url: url, title: title)
            }
            h.now = Date.init
        }
        mkShow(d, "work", "swiftui")
        mkSettleShown(timeout: 15, extra: 1.0)
        run { [self] in
            guard let page = c.pageView(for: c.currentSpaceID) else { return }
            page.layoutSubtreeIfNeeded()
            guard let tile = page.favorites.subviews.compactMap({ $0 as? FavoriteTileView })
                .first(where: { $0.item?.savedURL?.hasPrefix("https://linear.app/") == true }) else {
                return note("marketing: MISSING \(name): no Linear Favorite")
            }
            let p = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
            if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                tile.mouseEntered(with: e)
            }
        }
        wait(TabPreviewController.dwell + 1.0)
        run { [self] in
            if c.tabPreview.thumbnail != .service { note("marketing: MISSING \(name): the card shows \(c.tabPreview.thumbnail.rawValue)") }
        }
        mkWindowShot(name)
        run { [self] in
            if let row = c.tabPreview.shownRow { c.tabPreview.hoverEnded(row, event: nil) }
            c.tabPreview.hide()
        }
        wait(0.3)
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
