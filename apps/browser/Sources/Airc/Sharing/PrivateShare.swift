// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// H03 in a private window: File › Share (and a key the person gave it in Settings › Shortcuts) hands the system's share
/// picker the page's link alone, without trackers (SelectionShare, as the main window's Share does). No title and no page
/// content go with it, and Airc keeps nothing of it: no history, no recent item, nothing in the data folder. The menu
/// reaches it through PrivateWindowController.perform(menuTitle:).
extension PrivateWindowController {
    #if AIRC_TESTING
    /// The H03 check takes the share here instead of showing the picker (its menu needs a person).
    static var shareProbe: ((SelectionShare) -> Void)?
    #endif

    /// The share for the page on screen: its link alone (nil without a page, or for an address the picker doesn't take).
    var currentShare: SelectionShare? {
        guard let url = shownPage?.url else { return nil }
        return SelectionShare([url.absoluteString])
    }

    /// The picker at the top of the page card (a private window has no sidebar header to hang it from).
    func shareCurrent() {
        guard let share = currentShare else { return NSSound.beep() }
        #if AIRC_TESTING
        if let probe = Self.shareProbe { return probe(share) }
        #endif
        share.show(relativeTo: NSRect(x: card.bounds.midX - 1, y: card.bounds.maxY - 2, width: 2, height: 2), of: card, edge: .minY)
    }
}
