// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit

extension SnapshotRunner {
    /// A deterministic late batch uses the same replacement path as history/suggestion callbacks.
    /// Drive AppKit's text-field command delegate so no network timing or pointer position decides the race.
    func lateCommandSelectionCheck() {
        run { [self] in
            guard let target = try? c.store.openTab(url: "data:text/html,<title>Late result target</title>",
                                                   inSpace: c.currentSpaceID, activate: false, title: "Late result target") else {
                return check(false, "command selection: target fixture exists")
            }
            c.openCommandBar(mode: .newTab)
            guard let bar = c.commandBar else { return check(false, "command selection: Command Bar opens") }
            let search = CommandResult(title: "Search", subtitle: "", badge: "Search", icon: .symbol("magnifyingglass"),
                                       matches: [], action: .open(URL(string: "https://search.example/?q=late")!))
            let late = CommandResult(title: "Late suggestion", subtitle: "", badge: "Search", icon: .symbol("magnifyingglass"),
                                     matches: [], action: .open(URL(string: "https://search.example/?q=later")!))
            let tab = CommandResult(title: target.title, subtitle: "", badge: "Switch to Tab", icon: .symbol("globe"),
                                    matches: [], action: .tab(target.id))
            let field = NSTextField(), editor = NSTextView()
            func down() { _ = bar.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))) }
            bar.type("")
            bar.applyLateResultsForTesting([search, tab])
            bar.applyLateResultsForTesting([late, search, tab])
            check(bar.selected == 0 && bar.results[0].selectionID == late.selectionID,
                  "command selection: untouched selection follows the new top result")
            bar.type("")
            bar.applyLateResultsForTesting([search, tab])
            down()
            bar.applyLateResultsForTesting([search])
            check(bar.selected == 0, "command selection: missing selected result falls back to clamped index")
            bar.type("")
            bar.applyLateResultsForTesting([search, tab])
            down()
            check(bar.selected == 1, "command selection: Down selects the existing tab")
            let inline = bar.inlineText, count = c.store.state.tabs.count
            bar.applyLateResultsForTesting([late, search, tab])
            check(bar.selected == 2 && bar.results[bar.selected].selectionID == tab.selectionID,
                  "command selection: late batch above the tab preserves its identity")
            check(bar.inlineText == inline, "command selection: late batch leaves inline completion unchanged")
            _ = bar.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            check(c.shownTabID == target.id && c.store.state.tabs.count == count,
                  "command selection: Return after late suggestions opens the selected tab, not a search")
            c.closeCommandBar()
        }
    }
}
#endif
