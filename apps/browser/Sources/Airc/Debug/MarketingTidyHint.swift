// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shots of the sidebar's tidy card (AI/TidyHint.swift), the marketing scenario's part "tidyhint"
/// (`scripts/marketing-shots.sh --parts tidyhint`):
///   - tidy-hint: Personal with a long Today (made-up pages on example.* sites, a few last viewed hours ago), the card
///     at the top of Today: Tidy into folders, Archive old tabs, Pin a site to Favorites, the auto-archive choice;
///   - tidy-hint-dark: the same in the dark Work Space.
/// The extra tabs close afterwards, so later parts see the demo as it was.
extension SnapshotRunner {
    @MainActor func mkTidyHintShots(_ d: MarketingDemo) {
        let pages: [(url: String, title: String)] = [
            ("https://news.example.com/briefing", "Morning briefing"), ("https://news.example.com/harbour", "Harbour bridge reopens"),
            ("https://news.example.com/weather", "Weekend weather"), ("https://recipes.example.org/risotto", "Lemon risotto"),
            ("https://recipes.example.org/curry", "Weeknight curry"), ("https://recipes.example.org/list", "Shopping list"),
            ("https://shop.example.net/shoes", "Trail running shoes"), ("https://shop.example.net/jacket", "Rain jacket"),
            ("https://docs.example.com/start", "Getting started"), ("https://docs.example.com/config", "Configuration"),
            ("https://maps.example.com/ferry", "Ferry timetable"), ("https://music.example.net/focus", "Focus playlist"),
            ("https://photos.example.org/coast", "Album: Coast walk"), ("https://forum.example.com/tents", "Thread: tent advice"),
        ]
        var opened: [String] = []
        func shoot(_ spaceKey: String, tab: String, name: String, dark: Bool) {
            run { [self] in
                if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
                TidyHint.allowedInScripts = true
                TidyHint.dayOverride = "marketing-\(name)"
                c.store.setLocalValue(TidyHint.dayKey, nil)
            }
            mkShow(d, spaceKey, tab)
            run { [self] in
                guard let sid = d.space[spaceKey] else { return }
                let s = c.store, realNow = s.now
                for (n, p) in pages.enumerated().reversed() {
                    // The first four were last viewed four hours ago: the card offers to archive them.
                    if n < 4 { let t = realNow().addingTimeInterval(-4 * 3600); s.now = { t } }
                    if let t = try? s.openTab(url: p.url, inSpace: sid, activate: false, title: p.title) { opened.append(t.id) }
                    s.now = realNow
                }
                c.reloadAll(animated: false)
            }
            mkSettleShown()
            run { [self] in
                let k = c.pageView(for: d.space[spaceKey] ?? "")?.rows["tidyhint"] as? TidyHintCardView
                note(k == nil ? "marketing: MISSING \(name): no tidy card" : "marketing: \(name) card shown")
            }
            wait(0.5)
            mkWindowShot(name, dark: dark)
            run { [self] in
                for id in opened { _ = try? c.store.closeTab(id) }
                opened = []
                TidyHint.allowedInScripts = false
                TidyHint.dayOverride = nil
                NSApp.appearance = NSAppearance(named: .aqua)
                c.reloadAll(animated: false)
            }
            wait(0.4)
        }
        shoot("personal", tab: "apple", name: "tidy-hint", dark: false)
        shoot("work", tab: "linear", name: "tidy-hint-dark", dark: true)
    }
}
#endif
