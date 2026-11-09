// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

extension WindowController {
    /// Registered only by ParityCommandCatalog; no separate Command Bar path.
    func blockingCommandActions() -> [CommandAction] {
        MainActor.assumeIsolated {
        guard let center = BlockingCenter.shared else { return [] }
        var actions = [CommandAction(title: "Ad & Tracker Blocking Settings…", symbol: "shield.lefthalf.filled", hint: "", keywords: ["ads", "trackers", "privacy", "blocking", "lists"]) { [weak self] in
            self?.app?.showSettings(page: .profiles)
        }]
        if let page = displayedLinkPage, let url = page.url, ["http", "https"].contains(url.scheme ?? ""), center.profileEnabled(for: page) {
            let enabled = center.enabled(for: page)
            actions.append(CommandAction(title: enabled ? "Turn Off Blocking for This Site" : "Turn On Blocking for This Site", symbol: "shield.lefthalf.filled", hint: "", keywords: ["ads", "trackers", "allow", "exception", "blocking"]) { [weak page] in
                if let page, !page.isClosed { center.setSiteEnabled(!center.enabled(for: page), tab: page) }
            })
        }
        return actions
        }
    }
}
