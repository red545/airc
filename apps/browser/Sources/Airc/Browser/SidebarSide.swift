// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// WIN-5: the sidebar on the window's right (Settings → Appearance → Sidebar position). Arc never had the option
/// (research §2.10), so every left-edge rule is mirrored: the page card's insets, the sidebar's slide on ⌘S, the hover
/// reveal from the window's right edge, the resize handle on the sidebar's inner (left) edge, the Library sliding in
/// from the right, tab and folder previews to the left of the sidebar, the drop zone that pages to the next Space,
/// and the downloads card and update question over the footer. Space swipes keep their direction (left to right is
/// still first to last), and the traffic lights stay at the window's top left, over the page.
///
/// It's one setting for the app, kept in the window state; every window follows it live (WIN-7). Private windows and
/// Little Arc keep their own layouts.
extension WindowController {
    /// A frame laid out for a sidebar on the left, where it goes on screen.
    func mirroredForSidebar(_ r: NSRect) -> NSRect {
        guard sidebarOnRight else { return r }
        return NSRect(x: root.bounds.width - r.maxX, y: r.minY, width: r.width, height: r.height)
    }

    /// The store's sidebar position changed (this window's Settings, another window's, or a restored session).
    func sidebarSideMayHaveChanged() {
        let onRight = store.windowState.sidebarOnRight
        guard onRight != sidebarOnRight else { return }
        tabPreview.dismiss(suppressing: nil)
        folderPreview.hide()
        sidebarOnRight = onRight
        sidebar.header.onRight = onRight
        // A short cross-fade: sliding the sidebar across the page reads as a bug.
        if window.isVisible, !onMain({ AircMotion.prefersReducedMotion }) { root.layer?.add(AircMotion.crossfadeTransition(), forKey: "sidebarSide") }
        layoutRoot()
        root.layoutSubtreeIfNeeded()
        positionTrafficLights()
        MediaLibrary.shared.layoutPrompts()
        UpdateCenter.shared.confirm?.layoutInWindow()
    }
}

extension AppDelegate {
    /// Settings → Appearance: every window lays out again at once (the store tells each one).
    func setSidebarOnRight(_ onRight: Bool) {
        store.updateWindowState { $0.sidebarOnRight = onRight }
    }
}
