// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// P06d: Arc's "Open Little Arc when clicking on links with ⌥⌘ held" (its optionCommandClickLittleArcEntryPointEnabled,
/// on by default; Arc's October 2022 notes: "Command Option Click now opens links in Little Arc!"). A link in a page,
/// its Peek or a Little Airc page, clicked with ⌥⌘, opens in a new Little Airc window with the page's profile; the page
/// stays as it was. Links from other apps aren't affected: Arc has no modifier for them, so Settings → Links decides.
///
/// Neither engine tells the app which keys a link was clicked with (to Chromium, ⌥⌘ is ⌘'s background tab), so the app
/// keeps the last mouse-up in its own windows and asks it about the link that follows. One click, one link.
enum LittleArcLinkClicks {
    private struct Click {
        var flags: NSEvent.ModifierFlags
        var at: TimeInterval
        weak var window: NSWindow?
    }
    private static var last: Click?
    private static var monitor: Any?
    /// How long after the mouse-up a link still counts as that click's (both engines ask within milliseconds).
    static let within: TimeInterval = 1

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { e in
            last = Click(flags: e.modifierFlags, at: ProcessInfo.processInfo.systemUptime, window: e.window)
            return e
        }
    }

    /// Whether the last click in `window`, just now, held ⌥⌘ (⇧ may be held too; ⌃ makes it a right-click).
    static func heldOptionCommand(in window: NSWindow?) -> Bool {
        guard let c = last, let window, c.window === window, ProcessInfo.processInfo.systemUptime - c.at <= within else { return false }
        return c.flags.intersection([.command, .option, .control]) == [.command, .option]
    }

    /// The click has opened its link.
    static func used() { last = nil }
}

extension AppDelegate {
    /// The Space (so the profile) a page's link opens with in Little Airc, when it was clicked with ⌥⌘; nil otherwise.
    /// The page's own Space: a main window's tab or its Peek, or a Little Airc page. A private window's page stays there.
    func optionCommandClickSpace(_ request: EngineLinkRequest, from opener: EngineTab) -> String? {
        let space: String, window: NSWindow
        if let c = controllers.first(where: { $0.tabID(for: opener) != nil || $0.peek?.page === opener }) {
            space = c.tabID(for: opener).flatMap { store.tab($0)?.spaceID } ?? c.currentSpaceID
            window = c.window
        } else if let l = littleArcs.first(where: { $0.page === opener }) {
            space = l.spaceID
            window = l.window
        } else {
            return nil
        }
        guard LinkRouting.opensInLittleArc(url: request.url, userGesture: request.userGesture, disposition: request.disposition,
                                           heldOptionCommand: LittleArcLinkClicks.heldOptionCommand(in: window),
                                           enabled: settings.values.littleArcGlobal.opensOptionCommandClicks) else { return nil }
        LittleArcLinkClicks.used()
        return space
    }
}
