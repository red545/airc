// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import SwiftUI
import AircDesign

/// An ordinary view inside the browser window. It never creates a panel,
/// activates the application, changes the key window, or takes keyboard focus.
@MainActor enum BlockingNotices {
    private final class Entry {
        weak var window: NSWindow?
        weak var view: NSView?
        init(window: NSWindow, view: NSView) { self.window = window; self.view = view }
    }
    private static var shown: [ObjectIdentifier: Entry] = [:]
    static func profileChanged(in controller: WindowController) {
        shown.removeValue(forKey: ObjectIdentifier(controller.window))?.view?.removeFromSuperview()
        show(in: controller)
    }
    #if AIRC_TESTING
    static func overlay(in controller: WindowController) -> NSView? {
        shown[ObjectIdentifier(controller.window)]?.view
    }
    static func isShown(in controller: WindowController) -> Bool {
        controller.window.contentView?.layoutSubtreeIfNeeded()
        guard let view = overlay(in: controller), let parent = view.superview else { return false }
        return view.window === controller.window && !view.isHiddenOrHasHiddenAncestor
            && view.bounds.width >= 300 && view.bounds.height >= 120 && parent.bounds.contains(view.frame)
    }
    static func dismissForCheck(in controller: WindowController) {
        shown.removeValue(forKey: ObjectIdentifier(controller.window))?.view?.removeFromSuperview()
    }
    #endif
    static func show(in controller: WindowController, forCheck: Bool = false) {
        guard let app = controller.app, forCheck || !app.options.isAutomated,
              let center = BlockingCenter.shared, let content = controller.window.contentView,
              let profile = controller.store.space(controller.currentSpaceID)?.profileID else { return }
        guard center.settings.shouldOfferCoexistence(profile: profile, extensionIDs: center.blockers(profile: profile).map(\.id)) else { return }
        shown = shown.filter { $0.value.window != nil && $0.value.view?.superview != nil }
        let key = ObjectIdentifier(controller.window)
        guard shown[key] == nil else { return }
        let theme = controller.currentPalette.resolved
        let card = BlockingOfferCard(center: center, profile: profile) {
            shown.removeValue(forKey: key)?.view?.removeFromSuperview()
        }
        .padding(20).frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
        .environment(\.aircTheme, theme)
        let host = AircFirstClickHostingView(rootView: card)
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        shown[key] = Entry(window: controller.window, view: host)
    }
}
