// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of "What's new" after an update (Browser/WhatsNewCard.swift, docs/user/updates.md), the marketing
/// scenario's part "whatsnew" (`scripts/marketing-shots.sh --parts whatsnew`):
///   - whats-new-card: the Studio Space's design page, the sidebar's card "Airc 0.1.12 is here" with 0.1.12's and
///     0.1.11's highlights merged (the bundled WhatsNew.json), And more, See All and ×. Shown directly: no state file
///     or LastVersion changes.
///   - whats-new-tab (whatsnew2): the "What's New in Airc" tab after an update from 0.1.13 to 0.1.15 (Browser/
///     WhatsNewPage.swift): 0.1.15's lines with their details, Try it / Show me and the Command Bar's picture.
extension SnapshotRunner {
    func mkWhatsNewShots(_ d: MarketingDemo) {
        mkShow(d, "studio", "hig")
        mkSettleShown()
        run { [self] in
            guard let catalog = WhatsNewCenter.bundled,
                  let content = WhatsNewContent.merge(catalog, from: "0.1.10", current: "0.1.12") else {
                return note("marketing: MISSING whats-new-card: no WhatsNew.json")
            }
            WhatsNewCenter.shared.showForCheck(content)
        }
        wait(0.9)
        mkWindowShot("whats-new-card")
        run { WhatsNewCenter.shared.showForCheck(nil) }
        wait(0.4)
        var tab: String?
        run { [self] in tab = WhatsNewCenter.shared.openTab(from: "0.1.13", to: "0.1.15", in: c) }
        wait(1.2)
        mkWindowShot("whats-new-tab")
        run { [self] in if let tab { c.closeTab(tab) } }
        wait(0.4)
    }
}
#endif
