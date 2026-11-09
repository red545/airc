// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// The marketing shot of P03b, the marketing scenario's part "parityp03b" (`scripts/marketing-shots.sh --parts
/// parityp03b`):
///   - command-bar-remove-suggestion: "lisbon" in Travel, the pointer on a history row: its ✕ (Arc's) at the right end,
///     which removes the page from the suggestions and the history (⌥⌘⌫ from the keyboard).
extension SnapshotRunner {
    func mkParityP03bShots(_ d: MarketingDemo) {
        mkShow(d, "travel", "lisbon")
        mkSettleShown()
        run { [self] in
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("lisbon")
        }
        wait(1.4)
        run { [self] in
            guard let bar = c.commandBar else { return note("marketing: MISSING command-bar-remove-suggestion: no Command Bar") }
            // The second history row (the first is the highlighted top hit), as the pointer would find it.
            let history = bar.results.indices.filter { bar.results[$0].historyURL != nil }
            guard let i = history.dropFirst().first ?? history.first, bar.visibleRows.indices.contains(i) else {
                return note("marketing: MISSING command-bar-remove-suggestion: no history row (\(bar.resultTitles.prefix(4)))")
            }
            bar.visibleRows[i].setHoveredForTesting(true)
            note("marketing: remove-suggestion rows: " + bar.resultTitles.joined(separator: " | ") + ", ✕ on row \(i)")
        }
        wait(0.4)
        mkWindowShot("command-bar-remove-suggestion")
        run { [self] in c.closeCommandBar() }
        wait(0.3)
    }
}
#endif
