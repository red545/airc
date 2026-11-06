// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AppKit

/// `--script fullscreen` (owner P0, 2026-11-05): a real native full screen. Not in the default snapshot run: it takes
/// the display over (full screen is a macOS Space of its own) for about 15 s, so run it only while nobody is using the
/// Mac, on each engine:
///
///     open -g -n -W --env CFFIXED_USER_HOME=$HOME_DIR build/Airc.app --args --engine=webkit \
///       --snapshot $OUT --script fullscreen --ephemeral --data-dir $HOME_DIR/Airc
///
/// What no script can do is bring the titlebar down: that takes a real pointer at the top edge. The events scenario
/// covers the rest of FullScreen.swift by simulating the window delegate's calls.
extension SnapshotRunner {
    func fullScreenScenario() {
        let buttons = { [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { self.c.window.standardWindowButton($0) } }
        func waitFor(fullScreen: Bool) {
            step { [self] done in
                waitUntil({ self.c.window.styleMask.contains(.fullScreen) == fullScreen && self.c.isFullscreen == fullScreen }, timeout: 8) {
                    // AppKit's transition runs on a moment after the window reports its new state.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: done)
                }
            }
        }
        func backOut(_ how: String) {
            run { [self] in
                let w = c.window
                let centers = buttons().map { b -> CGPoint in
                    let r = b.convert(b.bounds, to: nil)
                    return CGPoint(x: r.midX, y: w.frame.height - r.midY)
                }
                let atArc = centers.count == 3 && zip(centers, AircMetrics.Window.trafficLightCenters).allSatisfy { abs($0.x - $1.x) <= 0.5 && abs($0.y - $1.y) <= 0.5 }
                check(!w.styleMask.contains(.fullScreen) && atArc && buttons().allSatisfy { !$0.isHidden && $0.window === w },
                      "real full screen: \(how) leaves full screen; the traffic lights are back at Arc's centres")
                check(!w.titlebarAccessoryViewControllers.contains { $0 is FullScreenRevealAccessory }, "real full screen: the reveal watcher is gone")
            }
        }
        waitForPage()
        run { [self] in c.window.toggleFullScreen(nil) }
        waitFor(fullScreen: true)
        run { [self] in
            check(c.window.styleMask.contains(.fullScreen), "real full screen: the window is in full screen")
            let titlebar = buttons().first?.window
            check(buttons().count == 3 && buttons().allSatisfy { !$0.isHidden } && titlebar != nil && titlebar !== c.window,
                  "real full screen: the traffic lights are unhidden in AppKit's titlebar window ("
                  + (titlebar.map { String(describing: type(of: $0)) } ?? "none") + "), which comes down with the menu bar")
            check(c.window.titlebarAccessoryViewControllers.contains { $0 is FullScreenRevealAccessory },
                  "real full screen: the menu-bar reveal is watched (the toggle steps aside while it is down)")
            check(c.toast.shownText == FullScreenController.toastText, "real full screen: the toast says \"\(c.toast.shownText ?? "nothing")\"")
            if let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu {
                FullScreenMenu.shared.menuNeedsUpdate(view)
                let title = view.items.first { $0.action == FullScreenMenu.action }?.title ?? "-"
                check(title == "Exit Full Screen", "real full screen: the View menu says \"\(title)\"")
            }
        }
        step { [self] done in captureWindow(c.window, name: "fs-01-full-screen", rounded: 0) { done() } }
        // Esc pressed twice, into the page.
        step { [self] done in
            let p = c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil)
            click(at: p, in: c.window, done)
        }
        key("\u{1b}", 53)
        key("\u{1b}", 53)
        waitFor(fullScreen: false)
        backOut("Esc pressed twice")
        // Again, then Esc held.
        run { [self] in c.window.toggleFullScreen(nil) }
        waitFor(fullScreen: true)
        run { [self] in
            let w = c.window
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                        isARepeat: false, keyCode: 53) { NSApp.postEvent(e, atStart: false) }
        }
        wait(0.9)
        run { [self] in
            let w = c.window
            if let e = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                        isARepeat: false, keyCode: 53) { NSApp.postEvent(e, atStart: false) }
        }
        waitFor(fullScreen: false)
        backOut("Esc held")
        // Never leave the display in full screen, whatever failed above.
        run { [self] in if c.window.styleMask.contains(.fullScreen) { c.window.toggleFullScreen(nil) } }
        wait(1.5)
    }
}
#endif
