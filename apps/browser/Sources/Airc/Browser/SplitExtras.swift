// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// P06c (parity audit row 25, V09): Split View's extras, as Arc's View menu has them.
///   - **Expand Current Split** (Arc's `maximizeCurrentSplitViewPane:`): the focused pane fills the split's place; the
///     others wait behind it, live and at their sizes. The same command (it says Restore Current Split then), the
///     pane's controls or the Command Bar bring the split back as it was, the expanded pane keeping the keyboard.
///     - Another pane taking the keyboard (⌃⇧[ ⌃⇧], ⌃⇧1–4, its sidebar segment), a pane joining or moving, the axis
///       changing and the split leaving the screen restore it too.
///     - Closing another pane keeps the expansion; closing the expanded pane brings the rest back.
///     - While expanded, ⌘[ / ⌘] are the page's Back and Forward, as for one page.
///     - It's the window's own state (Arc keeps it with the window's contents): each window has its own, nothing is
///       saved, and it's never an undo step. The split's sizes aren't touched.
///   - **Separate Page from Split View** (Arc's `separateTabFromSplitView:`): the focused pane becomes a tab of its own
///     (`separatePane`: below the split, or a pinned tab or Favorite beside a pinned or Favorite split). One undo step.
///   - **⌥-click on a split's sidebar row or Favorite tile** (Arc 1.17.2: "Option + Clicking on a Split View Tab in the
///     Sidebar now quickly separates the Split View into two tabs"): Separate All Tabs. One undo step
///     (`optionClickSplit`, SplitActions.swift).
extension WindowController {
    static let expandSplitTitle = "Expand Current Split"
    static let restoreSplitTitle = "Restore Current Split"

    /// A split is on screen in this window (the menu's Expand and Separate Page apply).
    var showsSplit: Bool { shownSplitID != nil && !splitContainer.isHidden }
    /// The pane expanded over its split, if any.
    var expandedPane: String? { showsSplit ? splitContainer.expandedTabID : nil }
    var expandSplitTitle: String { expandedPane == nil ? Self.expandSplitTitle : Self.restoreSplitTitle }

    /// View › Expand Current Split: the focused pane fills the split's place; again (Restore Current Split), the split
    /// comes back as it was.
    func toggleExpandedSplit() {
        guard showsSplit, let t = shownTabID else { return NSSound.beep() }
        splitContainer.setExpanded(expandedPane == nil ? t : nil, animated: true)
    }

    /// View › Separate Page from Split View: the focused pane.
    func separateFocusedPane() {
        guard showsSplit, let t = shownTabID else { return NSSound.beep() }
        separatePane(t)
    }
}

extension SplitContainerView {
    /// Expands `tabID`'s pane over the split (nil: restores the split), gliding from where it is.
    func setExpanded(_ tabID: String?, animated: Bool) {
        guard tabID != expandedTabID else { return }
        if let tabID {
            guard panes.count >= 2, let p = pane(for: tabID) else { return }
            if expandedTabID != nil { dropExpansion() }
            expandedTabID = tabID
            // It grows over the others; no ring and no dividers while it's alone.
            addSubview(p, positioned: .above, relativeTo: nil)
            for pane in panes { pane.focused = false }
            for d in dividers { d.isHidden = true }
            glide(p, to: bounds, animated: animated) { [weak self] in self?.layoutExpanded() }
        } else {
            guard let e = expandedTabID, let p = pane(for: e), let i = panes.firstIndex(where: { $0 === p }) else {
                expandedTabID = nil
                return
            }
            expandedTabID = nil
            // The others are back at their sizes behind it, and it shrinks back into its place.
            let end = frames(for: fractions)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (pane, r) in zip(panes, end) where pane !== p {
                pane.frame = r
                pane.isHidden = false
            }
            CATransaction.commit()
            glide(p, to: end[i], animated: animated) { [weak self] in
                guard let self else { return }
                self.needsLayout = true
                self.setFocused(self.controller?.shownTabID)
            }
        }
    }

    /// The expanded pane over the split's whole place, the others hidden behind it at their sizes, no dividers.
    func layoutExpanded() {
        guard let e = expandedTabID, let p = pane(for: e) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if p.frame != bounds { p.frame = bounds }
        p.isHidden = false
        for pane in panes {
            pane.focused = false
            if pane !== p { pane.isHidden = true }
        }
        for d in dividers { d.isHidden = true }
        CATransaction.commit()
    }

    /// `configure`'s first step: an expansion lasts while the same split, on the same axis, only loses panes other than
    /// the expanded one. Anything else (a pane joining or moving, another split) ends it first, and the panes then
    /// spring from where they are. True when it lasts.
    func expansionSurvives(_ split: Split, _ ids: [String]) -> Bool {
        guard let e = expandedTabID else { return false }
        if split.id == splitID, split.axis == axis, ids.count >= 2, ids.contains(e), ids == tabIDs.filter(ids.contains) { return true }
        dropExpansion()
        return false
    }

    /// Ends an expansion at once: every pane and divider shows again; the next layout puts them at their sizes.
    func dropExpansion() {
        guard expandedTabID != nil else { return }
        expandedTabID = nil
        for p in panes { p.isHidden = false }
        for d in dividers { d.isHidden = false }
        needsLayout = true
    }

    private func glide(_ p: SplitPaneView, to b: NSRect, animated: Bool, completion: @escaping () -> Void) {
        controller?.animator.cancel("split")
        let a = p.frame
        guard animated, canAnimate, a != b else {
            p.frame = b
            return completion()
        }
        controller?.animator.spring("split", from: 0, to: 1, spring: Spring(AircSpring.settle), update: { [weak p] t in
            let t = CGFloat(t)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            p?.frame = NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                              width: max(0, a.width + (b.width - a.width) * t), height: max(0, a.height + (b.height - a.height) * t))
            CATransaction.commit()
        }, completion: completion)
    }
}
