// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of Tidy Tabs (P18b), the marketing scenario's part "parityp18b"
/// (`scripts/marketing-shots.sh --parts parityp18b`):
///   - tidy-tabs: Personal with a few more Today tabs (a Japan trip, SwiftUI, type), tidied by Apple's on-device model
///     into folders at the top of Today (Today folders), with the "Grouped …" message and Tidy beside Clear,
///     over the Typography page on Wikipedia.
/// The folders are whatever the model makes (logged); where Apple Intelligence is off the part uses a scripted model
/// and says so in the log. Afterwards ⌘Z puts Today back and the extra tabs close, so later parts see the demo as it was.
extension SnapshotRunner {
    @MainActor func mkParityP18bShots(_ d: MarketingDemo) {
        let extra: [(url: String, title: String)] = [
            ("https://www.japan-guide.com/e/e3915.html", "Fushimi Inari Shrine – japan-guide.com"),
            ("https://developer.apple.com/documentation/swiftui/view", "View | Apple Developer Documentation"),
            ("https://fonts.google.com/", "Browse Fonts – Google Fonts"),
            ("https://www.japan-guide.com/railpass/", "Japan Rail Pass – japan-guide.com"),
            ("https://www.hackingwithswift.com/100/swiftui", "100 Days of SwiftUI – Hacking with Swift"),
            ("https://en.wikipedia.org/wiki/Helvetica", "Helvetica – Wikipedia"),
        ]
        var opened: [String] = []
        var space = ""
        // A calm page on screen (Typography on Wikipedia, which Tidy files under its folder): apple.com shows the build
        // Mac's region banner, and the message would sit on top of it.
        mkShow(d, "personal", "natoday")
        run { [self] in
            guard let sid = d.space["personal"] else { return }
            space = sid
            for t in extra.reversed() {
                if let tab = try? c.store.openTab(url: t.url, inSpace: sid, activate: false, title: t.title) { opened.append(tab.id) }
            }
            if !TidyTabsFeature.usesAppleIntelligence {
                note("marketing: tidy-tabs: Apple Intelligence \(AppleIntelligence.availability.label): a scripted model stands in")
                TidyTabsFeature.testOverride = (true, P18bTabsModel([
                    "Kyoto – Travel guide at Wikivoyage": "Japan Trip", "Fushimi Inari Shrine – japan-guide.com": "Japan Trip",
                    "Japan Rail Pass – japan-guide.com": "Japan Trip", "Swift.org": "Swift", "View | Apple Developer Documentation": "Swift",
                    "100 Days of SwiftUI – Hacking with Swift": "Swift", "Typography – Wikipedia": "Typography",
                    "Browse Fonts – Google Fonts": "Typography", "Helvetica – Wikipedia": "Typography",
                ]))
            }
            var o = TidyTabsPlanner.Options()
            o.timeout = 60
            TidyTabsFeature.options = o
            c.reloadAll(animated: false)
        }
        mkSettleShown()
        run { [self] in TidyTabsFeature.start(in: c, spaceID: space) }
        step { [self] done in waitUntil({ !TidyTabsFeature.isRunning(space) }, timeout: 120) { done() } }
        // Tidy shows its folders first (AI/TidyHint.swift); the shot is of them applied.
        run { [self] in if TidyHint.previews[space] != nil { TidyHint.apply(c, spaceID: space) } }
        run { [self] in
            if case .plan(let p) = TidyTabsFeature.lastOutcome[space] {
                for f in p.folders {
                    note("marketing: tidy-tabs folder \(f.name): " + f.tabIDs.compactMap { c.store.tab($0)?.title }.joined(separator: "; "))
                }
            } else {
                note("marketing: MISSING tidy-tabs: \(String(describing: TidyTabsFeature.lastOutcome[space])) \(TidyTabsFeature.lastMessage ?? "")")
            }
            c.pageView(for: space)?.sidebarHovered = true
        }
        wait(0.5)
        mkWindowShot("tidy-tabs")
        run { [self] in
            c.pageView(for: space)?.sidebarHovered = false
            if c.store.undoLabel == SpacesStore.tidyTabsLabel { c.undo() }
            for id in opened { _ = try? c.store.closeTab(id) }
            TidyTabsFeature.testOverride = nil
            TidyTabsFeature.options = TidyTabsPlanner.Options()
        }
    }
}
#endif
