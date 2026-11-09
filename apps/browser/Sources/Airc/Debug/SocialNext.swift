// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The social studio's motions of features that aren't in a release yet (SocialMotions.swift and SocialMotions013.swift
/// have the released ones). A build of a release's own source leaves this file out, and `--script social` then says
/// the motion is unknown:
///   - portrait: Capture in Portrait Mode of the trip page, the colour slider moved from cyan to yellow, then the
///     website's own colour (never the desktop picture: that's the person's own);
///   - devtoolbar: devtabs (SocialMotions013.swift) from main, whose Developer Mode toolbar adds Network;
///   - sitepreview: Work on the demo's shared folder, the pointer resting on the Linear Favorite, then Figma's, then the pinned
///     Notion page: each card lists the pages visited there (made-up visits in the demo's history, as
///     TabPreviewShots.swift records Linear's), newest first, with "+".
extension SnapshotRunner: SocialNextMotions {
    func socialNextMotion(_ motion: String) -> Bool {
        switch motion {
        case "portrait": socialPortrait()
        case "devtoolbar": socialDevTabs("devtoolbar")
        case "sitepreview": socialSitePreview()
        default: return false
        }
        return true
    }

    // MARK: Capture in Portrait Mode

    func socialPortrait() {
        let reel = SocialReel("portrait")
        let server = socialServer()
        let suite = "org.airc.social.portrait.\(getpid())"
        run {
            UserDefaults().removePersistentDomain(forName: suite)
            PortraitStyle.storage = { UserDefaults(suiteName: suite)! }   // never the person's own choices
        }
        let tab = socialTripTab("/lisbon", "Lisbon, four days")
        socialOverlayFrame(reel, hold: 0.9, label: "page")
        run { [self] in c.startCapture(portrait: true) }
        step { [self] done in
            waitUntil({ CaptureSession.active(in: self.c.window).map { $0.picturesReady && $0.portrait != nil } ?? true }, timeout: 20) { done() }
        }
        wait(0.5)
        socialOverlayFrame(reel, hold: 1.4, label: "portrait")
        // The slider from cyan to yellow over 0.8 s (the slider runs pink, red, orange, yellow, green, cyan, blue).
        let steps = 24
        for k in 1...steps {
            let p = Double(k) / Double(steps)
            let v = 0.85 - 0.55 * (p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2)
            run { [self] in CaptureSession.active(in: c.window)?.portraitStyleChanged(PortraitStyle(background: .color, colorPercentage: v)) }
            wait(0.15)
            socialOverlayFrame(reel, hold: k == steps ? 1.0 : 1.0 / 30, label: "colour")
        }
        run { [self] in CaptureSession.active(in: c.window)?.portraitStyleChanged(PortraitStyle(background: .website, colorPercentage: 0.3)) }
        wait(0.5)
        socialOverlayFrame(reel, hold: 2.4, label: "website")
        socialWrite(reel)
        run { [self] in
            CaptureSession.active(in: c.window)?.cancel()
            UserDefaults().removePersistentDomain(forName: suite)
            PortraitStyle.storage = { .standard }
            if let t = tab.value { c.closeTab(t) }
            server.value?.stop()
        }
    }

    // MARK: Site previews

    func socialSitePreview() {
        let reel = SocialReel("sitepreview")
        // Visits in the Work profile's history, at their times: TabPreviewShots.swift's Linear pages, and Figma files and
        // Notion pages of the same made-up company. Nothing is fetched: a card lists what the history has.
        run { [self] in
            guard let h = c.app?.history, let space = socialSpace("Work") else { return note("social: MISSING sitepreview: no Work Space") }
            let profile = c.store.profile(ofSpace: space).id
            let now = Date()
            for (url, title, minutes) in [
                ("https://linear.app/papertrail/view/release-blockers", "Release blockers", 60.0 * 26),
                ("https://linear.app/papertrail/issue/WEB-131/onboarding-flow-redesign", "WEB-131 Onboarding flow redesign", 60.0 * 5),
                ("https://linear.app/papertrail/my-issues/assigned", "My issues", 75.0),
                ("https://linear.app/papertrail/project/launch", "Launch checklist", 26.0),
                ("https://linear.app/papertrail/issue/WEB-142/sync-status-in-the-sidebar", "WEB-142 Sync status in the sidebar", 9.0),
                ("https://linear.app/papertrail/team/WEB/active", "WEB › Active issues", 0.4),
                ("https://www.figma.com/design/demo-brand/Brand-guidelines", "Brand guidelines", 60.0 * 30),
                ("https://www.figma.com/design/demo-launch-site/Launch-site", "Launch site", 60.0 * 3),
                ("https://www.figma.com/design/demo-app-icons/App-icons", "App icons", 48.0),
                ("https://www.figma.com/design/demo-onboarding/Onboarding-flow", "Onboarding flow", 6.0),
                ("https://www.notion.so/demo-launch-plan", "Launch plan", 60.0 * 20),
                ("https://www.notion.so/demo-hiring", "Hiring: design engineer", 60.0 * 4),
                ("https://www.notion.so/demo-weekly-sync", "Weekly sync notes", 95.0),
                ("https://www.notion.so/demo-q4-roadmap", "Q4 roadmap", 3.0),
            ] as [(String, String, Double)] {
                h.now = { now.addingTimeInterval(-minutes * 60) }
                h.recordVisit(profileID: profile, url: url, title: title)
            }
            h.now = Date.init
        }
        // The page behind the cards is the demo's own shared folder (its server), not a site with someone's artwork on it.
        let server = socialServer()
        run { [self] in
            guard let s = socialSpace("Work") else { return note("social: MISSING Space Work") }
            c.switchToSpace(s, animated: false)
            let url = MarketingDemo.site("files", "/shared")
            var id = c.store.todayTabs(ofSpace: s).first { $0.url == url }?.id
            if id == nil {
                id = (try? c.store.openTab(url: url, inSpace: s, activate: false, title: "Launch assets – Shared folder"))?.id
                c.reloadAll(animated: false)
            }
            if let id { c.show(id, focus: false) } else { note("social: MISSING sitepreview: no shared-folder tab") }
        }
        mkSettleShown(timeout: 20, extra: 1.5)
        socialFrame(reel, hold: 1.1, label: "page")
        let favorite = { [self] (prefix: String) -> NSView? in
            c.pageView(for: c.currentSpaceID)?.favorites.subviews.compactMap { $0 as? FavoriteTileView }
                .first { $0.item?.savedURL?.hasPrefix(prefix) == true }
        }
        let pinned = { [self] (part: String) -> NSView? in
            c.pageView(for: c.currentSpaceID)?.rows.values
                .first { ($0 as? TabPreviewRow)?.previewEntry?.item?.savedURL?.contains(part) == true }
        }
        for (label, hold, find) in [("linear", 2.4, { favorite("https://linear.app/") }), ("figma", 2.0, { favorite("https://www.figma.com/") }),
                                    ("notion", 2.4, { pinned("notion.so/demo-q4-roadmap") })] as [(String, Double, () -> NSView?)] {
            run { [self] in
                c.pageView(for: c.currentSpaceID)?.layoutSubtreeIfNeeded()
                if let r = c.tabPreview.shownRow { c.tabPreview.hoverEnded(r, event: nil) }
                guard let v = find() else { return note("social: MISSING sitepreview: no \(label) row") }
                // The pointer resting on it, as its own hover handler sees it (no cursor is drawn, as in every frame).
                let p = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                    v.mouseEntered(with: e)
                }
            }
            wait(TabPreviewController.dwell + 1.0)
            run { [self] in
                if c.tabPreview.thumbnail != .service { note("social: sitepreview: the \(label) card shows \(c.tabPreview.thumbnail.rawValue)") }
            }
            socialFrame(reel, hold: hold, label: label)
        }
        socialWrite(reel)
        run { [self] in
            if let r = c.tabPreview.shownRow { c.tabPreview.hoverEnded(r, event: nil) }
            c.tabPreview.hide()
            server.value?.stop()
        }
        wait(0.3)
    }
}
#endif
