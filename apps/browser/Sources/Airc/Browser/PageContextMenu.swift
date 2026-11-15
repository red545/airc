// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

extension WindowController {
    func tab(_ tab: EngineTab, pageMenu context: [String: Any]) -> [[String: String]] {
        SelectionSearchMenu.items(context, search: selectionSearch(for: tab)) +
        [ ["id": "capture", "title": "Capture"],
          ["id": "capture.full", "title": "Capture Full Page"],
          ["id": "capture.portrait", "title": "Capture in Portrait Mode"] ]
    }
    func tab(_ tab: EngineTab, pageMenuCommand id: String) {
        guard tab.view.window === window else { return }
        // Native menu tracking must finish before a capture overlay takes focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let q = SelectionSearchMenu.query(fromID: id) {
                // Chrome's "Search … for": a new tab in front, here a Today tab of the page's Space.
                if let url = SelectionSearch.url(q, search: self.selectionSearch(for: tab)) { self.navigate(to: url, newTab: true) }
                return
            }
            if let tabID = self.tabID(for: tab), self.shownTabID != tabID { self.show(tabID, focus: false) }
            switch id {
            case "capture": self.startCapture()
            case "capture.full": self.startCapture(fullPage: true)
            case "capture.portrait": self.startCapture(portrait: true)
            default: break
            }
        }
    }
    func selectionSearchName(for tab: EngineTab) -> String? { selectionSearch(for: tab).name }

    /// SP-31 "Open Link in Space ›": this window's Spaces in sidebar order, every profile's (a blank window: its own),
    /// each titled with its emoji. Pages of other windows, Peek included, ask their own window.
    func linkSpaces(for tab: EngineTab) -> [[String: String]] {
        guard tabID(for: tab) != nil || peek?.page === tab else { return [] }
        return LinkSpaceMenu.rows(spaces: store.orderedSpaces, current: store.space(currentSpaceID))
    }

    /// A new Today tab in the chosen Space (its profile), which this window switches to, like a rule's link.
    func tab(_ tab: EngineTab, openLink url: URL, inSpace spaceID: String) {
        guard LinkSpaceMenu.opens(url), tabID(for: tab) != nil || peek?.page === tab,
              linkSpaces(for: tab).contains(where: { $0["id"] == spaceID }) else { return }
        // After the menu's tracking loop ends.
        DispatchQueue.main.async { [weak self] in self?.openExternal(url, inSpace: spaceID) }
    }

    /// The profile's default search (P07d: a site search made the default included) of the Space showing `tab`.
    private func selectionSearch(for tab: EngineTab) -> DefaultSearch {
        store.profile(ofSpace: currentSpaceID).defaultSearch
    }
}

/// C08: "Search <engine> for “…”" on selected text, in place of Chromium's own item (which names Chromium's default
/// provider, not the profile's engine). The selection travels in the item's id, so the command needs no state.
enum SelectionSearchMenu {
    static let prefix = "search.selection:"

    /// The item for the selection in a Chromium menu's `context` ("selection"), replacing Chromium's search items.
    static func items(_ context: [String: Any], search: DefaultSearch) -> [[String: String]] {
        guard let s = context["selection"] as? String, let q = SelectionSearch.query(s),
              let title = SelectionSearch.title(q, search: search) else { return [] }
        return [["id": prefix + q, "title": title, "replaces": "search"]]
    }

    static func query(fromID id: String) -> String? {
        id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
    }
}
