// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// Boosts' marketing shots (BST-1), through the marketing scenario's hook for features in other files
/// (MarketingScenario.swift, `MarketingExtraShots`): `AIRC_MARKETING_PART=boosts`, or `scripts/marketing-shots.sh
/// --parts boosts`. Wikipedia's Typography article in the demo's Personal Space, boosted into a warm, bookish page
/// (a soft amber tint and Charter, the Appearance column zapped), with the Boost editor open on Colors, then on Font
/// and Zap. The Boost is removed afterwards.
extension SnapshotRunner: MarketingExtraShots {
    func marketingExtraShots(part: String, demo d: MarketingDemo) {
        guard part == "boosts" else { return }
        mkShow(d, "personal", "natoday")
        mkSettleShown(timeout: 15, extra: 0.8)
        run { [self] in
            BoostCenter.shared?.update(domain: "wikipedia.org") {
                $0.colors = BoostColors(hue: 0.09, tint: 0.38, brightness: 1, contrast: 1.04, invert: false)
                $0.font = BoostFont(family: .charter, size: 1)
                $0.zaps = [BoostZap(selector: ".vector-column-end", label: "Appearance")]
            }
            c.showBoostEditor(section: .colors)
        }
        wait(1.2)
        mkWindowShot("boosts")
        run { [self] in c.boostEditor?.model.section = .font }
        wait(0.8)
        mkWindowShot("boosts-font")
        run { [self] in c.boostEditor?.model.section = .zap }
        wait(0.8)
        mkWindowShot("boosts-zap")
        run { [self] in
            c.closeBoostEditor(animated: false)
            BoostCenter.shared?.remove(domain: "wikipedia.org", page: nil)
        }
    }
}
#endif
