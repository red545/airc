// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AppKit
import SwiftUI

/// The one-time hint after onboarding: "Ask Airc to do things for you", pointing at the sidebar's Airc Agent button.
/// Once per Mac (remembered in the user defaults), dismissable, never during onboarding (it shows a few seconds after the
/// browser window took over) and never in scripted runs unless a check asks.
enum AgentButtonHint {
    static let shownKey = "AircAgentButtonHintShown"
    static var wasShown: Bool { UserDefaults.standard.bool(forKey: shownKey) }
    private static var popover: NSPopover?

    /// The hint on screen (checks).
    static var shownView: NSView? { popover?.isShown == true ? popover?.contentViewController?.view : nil }

    /// Onboarding just handed over to the browser window.
    static func afterOnboarding(_ c: WindowController) {
        guard !LaunchOptions.current.isAutomated else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak c] in
            guard let c else { return }
            _ = show(in: c)
        }
    }

    /// Shows it over the window's Airc Agent button if it hasn't been shown on this Mac. Nil when it isn't shown (already
    /// seen, onboarding still up, sidebar hidden, window not on screen).
    @discardableResult
    static func show(in c: WindowController, force: Bool = false) -> NSPopover? {
        guard force || !wasShown, c.app?.onboarding == nil, c.window.isVisible, !c.window.isMiniaturized else { return nil }
        let button = c.sidebar.footer.agentButton
        guard button.window === c.window, !button.isHiddenOrHasHiddenAncestor, button.bounds.width > 0 else { return nil }
        popover?.close()
        let theme = c.currentPalette.resolved
        let content = AgentButtonHintView(
            tryIt: { popover?.close(); AgentUI.toggle(c) },
            dismiss: { popover?.close() }
        ).environment(\.aircTheme, theme)
        let v = AircFirstClickHostingView(rootView: content.testAnchorRoot())
        v.frame.size = v.fittingSize
        let vc = NSViewController()
        vc.view = v
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        p.contentViewController = vc
        p.contentSize = v.fittingSize
        popover = p
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        UserDefaults.standard.set(true, forKey: shownKey)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Ask Airc to do things for you: the Airc Agent button, or Option Command A.",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        AgentCenter.shared.onEvent?("agent-button-hint shown")
        return p
    }

    static func close() { popover?.close() }

    #if AIRC_TESTING
    static func resetForTesting() { UserDefaults.standard.removeObject(forKey: shownKey); popover?.close() }
    #endif
}

struct AgentButtonHintView: View {
    let tryIt: () -> Void
    let dismiss: () -> Void
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(theme.accent.color)
                Text("Ask Airc to do things for you").aircFont(AircFont.body).fontWeight(.semibold)
                    .foregroundStyle(theme.surfaceText.color).testAnchor("agenthint.title")
            }
            Text("Click here, or press ⌥⌘A. It works in your signed-in sites in the background and asks before paying, sending or posting. Use your own Claude Code or Codex, or an API key.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button("Not now", action: dismiss).buttonStyle(.airc(.secondary, size: .small)).testAnchor("agenthint.dismiss")
                Button("Try it", action: tryIt).buttonStyle(.airc(.primary, size: .small)).testAnchor("agenthint.try")
            }
        }
        .padding(14)
        .frame(width: 290)
        .testAnchor("agenthint")
    }
}
