// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Marketing shots for features that had none, parts of `--script marketing` (`scripts/marketing-shots.sh --parts …`):
///   - `favbadges` (S03b): favorite-badges, favorite-badges-dark. The Work Space's Favorites with their own badges:
///     X's count, Slack's @ mention, Gmail's dot, the Calendar's bright "meeting soon" pill and a call's camera badge.
///     Titles are set on the saved Favorites (no X or Slack page loads); the call is a plain loopback page marked as in
///     a call, as MarketingParityP16b does; the meeting comes from the synthetic calendar.
///   - `mailcard` (S04): mail-preview. A pinned Gmail look-alike (S04MailFixtures on 127.0.0.1, fictional mail) loaded
///     in the background; resting on its row shows the card with the unread messages.
///   - `profilesearch` (C08): settings-profiles-search. Settings › Profiles with each profile's default search engine
///     and "Include search engine suggestions".
extension SnapshotRunner {
    // MARK: favbadges

    func mkFavoriteBadgeShots(_ d: MarketingDemo) {
        var server: LocalPageServer?
        var callTab = "", callItem = "", calItem = ""
        let calendar = CalendarCenter.shared
        var offset: TimeInterval = 0
        let t0 = Date()
        let meeting = CalendarEvent(id: "crit", title: "Design crit", start: t0.addingTimeInterval(3600), end: t0.addingTimeInterval(5400),
                                    link: MeetingLink(url: URL(string: "https://meet.google.com/abc-mnop-xyz")!, service: .meet))
        // A plain page standing for a call app: its own icon, no media (MarketingParityP16b's way of marking a call).
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='8' fill='#2F8F6B'/>"
            + "<path d='M8 11h11a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2v-6a2 2 0 0 1 2-2zm14 4 5-3v8l-5-3z' fill='white'/></svg>"
        let callPage = "<!doctype html><meta charset=utf-8><title>Weekly design sync</title>"
            + "<link rel='icon' href='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())'>"
            + "<body style='margin:0;background:#16181d'>"
        step { [self] done in
            server = LocalPageServer(pages: ["/sync": callPage])
            server?.start { port in
                guard let port, let sid = d.space["work"] else { self.note("marketing: MISSING favorite-badges: no call page"); return done() }
                do {
                    let s = self.c.store
                    // X's count and Slack's mention, read from the Favorites' titles as Arc did.
                    try self.favorite("https://x.com/home", title: "(12) Home / X", icon: nil, profile: d.work, space: sid)
                    if let slack = s.favorites(ofProfile: d.work).first(where: { $0.savedURL?.hasPrefix("https://app.slack.com/") == true }) {
                        try s.replaceSavedURL(ofItem: slack.id, with: slack.savedURL ?? "", title: "! Slack | design-team | Papertrail")
                    }
                    calItem = s.favorites(ofProfile: d.work).first { CalendarSites.isCalendarFavorite($0.savedURL ?? "") }?.id ?? ""
                    let t = try s.openTab(url: "http://127.0.0.1:\(port)/sync", inSpace: sid, activate: false, title: "Weekly design sync")
                    try s.move(.tab(t.id), to: .favorites(profileID: d.work, index: 99))
                    callTab = t.id
                    callItem = s.tab(t.id)?.itemID ?? ""
                } catch { self.note("marketing: MISSING favorite-badges: \(error)") }
                self.c.reloadAll(animated: false)
                done()
            }
        }
        mkPutAwaySignInCards()   // MarketingParityP12.swift: no "Sign in to Google" card
        // The call's page loads once it's opened (Favorites load when used), then Work goes back to SwiftUI's docs.
        run { [self] in
            if let it = c.store.item(callItem) { c.activate(entry: .favorite(it, c.store.liveTab(forItem: callItem))) }
        }
        step { [self] done in waitUntil({ self.c.engineTab(for: callTab)?.isLoading == false }, timeout: 10) { done() } }
        mkShow(d, "work", "swiftui")
        mkSettleShown(timeout: 15, extra: 1.0)
        run { [self] in
            CallTools.shared.update(callTab, page: c.engineTab(for: callTab), active: true)
            guard let source = calendar.source as? SyntheticCalendarSource else { return note("marketing: MISSING favorite-badges: not the synthetic calendar") }
            // 4 min 50 s before the meeting: the countdown on its bright "meeting soon" pill.
            offset = meeting.start.timeIntervalSince(t0) - (4 * 60 + 50)
            calendar.now = { t0.addingTimeInterval(offset) }
            source.set([meeting])
            calendar.setEnabled(true)
            calendar.clockMoved()
            c.reloadAll(animated: false)
            c.show(d.tab["swiftui"] ?? "", focus: false)
        }
        step { [self] done in waitUntil({ calendar.tileLabel != nil }, timeout: 3) { done() } }
        wait(1.0)
        for dark in [false, true] {
            run { [self] in
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                // The call badge again: MediaCenter may have looked at the page meanwhile.
                CallTools.shared.update(callTab, page: c.engineTab(for: callTab), active: true)
                c.reloadAll(animated: false)
                c.show(d.tab["swiftui"] ?? "", focus: false)
            }
            mkSettleShown(timeout: 10, extra: 1.0)
            run { [self] in
                guard let p = c.pageView(for: c.currentSpaceID) else { return }
                p.layoutSubtreeIfNeeded()
                let faces = p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.map { t -> String in
                    MainActor.assumeIsolated {
                    let badge: String
                    switch t.shownUnreadBadge {
                    case .none: badge = "-"
                    case .dot: badge = "dot"
                    case .count(let n, _): badge = "count \(n)"
                    case .mention: badge = "@"
                    }
                    let call = t.audioBadge.map { $0.layer.isHidden ? "" : " \($0.state)" } ?? ""
                    let pill = t.item?.id == calItem ? " pill \(t.calendarFace?.text ?? "-") soon \(t.calendarFace?.isSoon == true)" : ""
                    return "\(t.item?.pageTitle ?? "?"): \(badge)\(call)\(pill)"
                    }
                }
                note("marketing: favorite badges: " + faces.joined(separator: " | "))
            }
            mkWindowShot(dark ? "favorite-badges-dark" : "favorite-badges", dark: dark)
        }
        run { [self] in
            NSApp.appearance = NSAppearance(named: .aqua)
            CallTools.shared.update(callTab, page: nil, active: false)
            calendar.setEnabled(false)
            calendar.now = Date.init
            calendar.clockMoved()
            server?.stop()
        }
    }

    // MARK: mailcard

    func mkMailCardShot(_ d: MarketingDemo) {
        let name = "mail-preview"
        let fx = S04MailFixtures()
        let center = ServicePreviewCenter.shared
        var server: LocalPageServer?
        var gmailURL = "", gmailItem = "", gmailTab = ""
        let m: (String, String, String, String, String, Double) -> S04MailFixtures.Message = {
            .init(id: $0, sender: $1, address: $2, subject: $3, snippet: $4, minutesAgo: $5)
        }
        step { [self] done in
            fx.set(gmail: [
                m("19a01", "Maya Lindqvist", "maya@example.com", "Lisbon: the tram tickets", "Booked the 28 for Saturday morning, see you at Martim Moniz.", 4),
                m("19a02", "Tomás Ferreira", "tomas@example.org", "Alfama loft check-in", "The key box code is in the app. Ring me if the door sticks.", 38),
                m("19a03", "Field Notes Weekly", "hello@example.net", "A quieter web, issue 41", "Five small sites that load in under a second.", 60 * 3),
                m("19a04", "Priya Natarajan", "priya@example.com", "Photos from Sintra", "Finally sorted them. The palace ones came out well.", 60 * 20),
            ], outlook: [], feed: "ok")
            server = LocalPageServer(responses: [:])
            // The fixture's inbox is "fixture@example.com"; the shot's account is a neutral you@example.com.
            server?.requestHandler = { r in
                guard var p = fx.answer(r) else { return nil }
                p.body = p.body.replacingOccurrences(of: "fixture@example.com", with: "you@example.com")
                return p
            }
            server?.start { port in fx.port = port ?? 0; done() }
        }
        run { [self] in
            guard fx.port != 0, let sid = d.space["personal"] else { return note("marketing: MISSING \(name): no fixture server") }
            PreviewService.loopbackFixtures = ["127.0.0.1": .gmail]
            ServicePreviewCenter.refreshAfter = 2
            PageMailProvider.tick = 1
            center.pageMail.stop()
            center.pageMail.start()
            gmailURL = "http://127.0.0.1:\(fx.port)/mail/u/0/#inbox"
            do {
                try pin(gmailURL, title: "Gmail", icon: "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico", space: sid)
                gmailItem = c.store.pinnedRoots(ofSpace: sid).last { $0.savedURL == gmailURL }?.id ?? ""
            } catch { note("marketing: MISSING \(name): \(error)") }
            app?.history.recordVisit(profileID: d.personal, url: gmailURL, title: "Inbox - Gmail")
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
            // Open the pinned Gmail, so its page is the account's session the card reads from.
            if let it = c.store.item(gmailItem) { c.activate(entry: .pinned(it, depth: 0, c.store.liveTab(forItem: gmailItem))) }
        }
        step { [self] done in
            waitUntil({
                gmailTab = self.c.store.liveTab(forItem: gmailItem)?.id ?? ""
                if case .mail(let mail)? = center.state(PreviewAccount(url: gmailURL, profileID: d.personal)!)?.content { return mail.count == 4 }
                return false
            }, timeout: 20) { done() }
        }
        // Back on Swift.org, the Gmail page loaded behind it; the pointer comes to rest on the Gmail row.
        mkShow(d, "personal", "swift")
        mkSettleShown(timeout: 15, extra: 1.0)
        run { [self] in
            guard let page = c.pageView(for: c.currentSpaceID) else { return }
            page.layoutSubtreeIfNeeded()
            guard let row = page.list.subviews.compactMap({ $0 as? TabRowView }).first(where: { $0.entry?.item?.id == gmailItem }) else {
                return note("marketing: MISSING \(name): no Gmail row")
            }
            let p = row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
            if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                row.mouseEntered(with: e)
            }
        }
        wait(TabPreviewController.dwell + 1.2)
        run { [self] in
            if c.tabPreview.thumbnail != .service { note("marketing: MISSING \(name): the card shows \(c.tabPreview.thumbnail.rawValue)") }
            if case .mail(let mail)? = c.tabPreview.serviceCard?.model.state.content {
                note("marketing: \(name): \(mail.count) messages, Gmail tab \(gmailTab.isEmpty ? "-" : "loaded")")
            } else {
                note("marketing: MISSING \(name): no mail on the card (\(String(describing: c.tabPreview.serviceCard?.model.state)))")
            }
        }
        mkWindowShot(name)
        run { [self] in
            if let row = c.tabPreview.shownRow { c.tabPreview.hoverEnded(row, event: nil) }
            c.tabPreview.hide()
            center.pageMail.stop()
            PreviewService.loopbackFixtures = [:]
            server?.stop()
        }
        wait(0.3)
    }

    // MARK: profilesearch

    func mkProfileSearchShot(_ d: MarketingDemo) {
        let name = "settings-profiles-search"
        run { [self] in
            app?.settings.values.suggestionsEnabled = true
            try? c.store.updateProfile(d.personal) { $0.searchEngine = .duckDuckGo; $0.searchSuggestions = true }
            try? c.store.updateProfile(d.work) { $0.searchEngine = .kagi; $0.searchSuggestions = false }
            NSApp.appearance = NSAppearance(named: .aqua)
            c.app?.showSettings(page: .profiles)
            if let w = c.app?.settingsWindow?.window { w.setFrameOrigin(NSPoint(x: -6000, y: 200)) }
        }
        wait(1.0)
        step { [self] done in
            defer { done() }
            guard let w = c.app?.settingsWindow?.window, let view = w.contentView, let img = mkContentImage(w) else {
                return note("marketing: MISSING \(name): no Settings window")
            }
            let (canvas, origin) = MarketingStudio.canvas(around: view.bounds.size)
            mkWrite(name, canvas: canvas, dark: false, [
                MarketingStudio.Layer(image: img, frame: NSRect(origin: origin, size: view.bounds.size), dark: false, lights: mkLights(w)),
            ])
        }
        run { [self] in c.app?.settingsWindow?.window.orderOut(nil) }
        wait(0.3)
    }
}
#endif
