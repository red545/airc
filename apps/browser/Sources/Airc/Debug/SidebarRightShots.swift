// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of the sidebar on the right (WIN-5), the marketing scenario's part "sidebarright"
/// (`scripts/marketing-shots.sh --parts sidebarright`):
///   - sidebar-right: Travel on the Lisbon article with the sidebar on the right, the traffic lights at the window's
///     top left over the page.
/// The setting goes back to the left afterwards.
extension SnapshotRunner {
    func mkSidebarRightShots(_ d: MarketingDemo) {
        run { [self] in app?.setSidebarOnRight(true) }
        mkShow(d, "travel", "lisbon")
        mkSettleShown()
        wait(0.4)   // the side's cross-fade
        mkWindowShot("sidebar-right")
        run { [self] in app?.setSidebarOnRight(false) }
    }
}
#endif
