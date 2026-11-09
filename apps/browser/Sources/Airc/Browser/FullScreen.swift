// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AppKit
import ObjectiveC

/// Native full screen (WIN-3; owner P0, 2026-11-05: in full screen there was no visible way out).
///
/// - **Traffic lights.** In full screen AppKit moves the titlebar into a window of its own, which comes down with the
///   menu bar when the pointer reaches the top edge and goes back up with it. The buttons only have to stay unhidden
///   there (WindowController.positionTrafficLights), so they show exactly while the menu bar does. While that titlebar
///   is down, the sidebar's toggle steps right of them, to its windowed place, and back when it goes up.
/// - **Esc** (Arc, arc_behavior_spec "Full screen"): a single Esc goes to the page (its dialog, its video); pressing it
///   twice within 0.5 s, or holding it for 0.6 s, leaves full screen. Esc that an Airc overlay or a text field uses
///   (Command Bar, find, cards, renaming) never counts. AppKit's own default, leaving on one Esc that nothing used, is
///   kept from happening: with no page focused here (escapeDown), from a WebKit page in RootView.cancelOperation.
/// - Entering shows "To exit full screen, press ⎋ twice or ⌃⌘F." for 4.8 s; View → Exit Full Screen (⌃⌘F) leaves.
final class FullScreenController {
    private unowned let c: WindowController
    /// The full-screen titlebar (and the traffic lights in it) is down, with the menu bar.
    private(set) var titlebarRevealed = false
    private var reveal: FullScreenRevealAccessory?
    private var exiting = false
    private var lastEscape: TimeInterval?
    /// The newest Esc key-down seen. WebKit hands a key the page didn't cancel back to AppKit, so the monitor sees
    /// the same event (its timestamp) again, sometimes only after the next real press when the Mac is busy.
    private var lastEscapeSeen: TimeInterval?
    private var escapeHold: DispatchWorkItem?
    /// How many times something asked to leave full screen (the real-event checks count them).
    private(set) var exitRequests = 0

    static let doublePress: TimeInterval = 0.5
    static let hold: TimeInterval = 0.6
    static let toastText = "To exit full screen, press ⎋ twice or ⌃⌘F."

    init(controller: WindowController) { c = controller }

    // MARK: Window delegate

    func willEnter() {
        exiting = false
        c.isFullscreen = true
        titlebarRevealed = false
        updateHeader(animated: false)
        c.positionTrafficLights()
    }

    func didEnter() {
        // Only a window that really is in full screen has the titlebar window to watch (the checks simulate entering).
        if c.window.styleMask.contains(.fullScreen), reveal == nil {
            let r = FullScreenRevealAccessory()
            r.onChange = { [weak self] amount in self?.revealChanged(amount) }
            c.window.addTitlebarAccessoryViewController(r)
            reveal = r
        }
        guard NSApp.isActive || c.app?.options.isAutomated == true else { return }
        c.toast.show(Self.toastText, palette: c.currentPalette, in: c.card.frame, duration: AircMetrics.Toast.fullScreenDuration)
    }

    func willExit() {
        // AppKit still owns the fullscreen titlebar until didExit. Removing its accessory here
        // with isFullscreen already false lets frame observers resize that container as AppKit
        // retiles it. _syncToolbarPosition then recursively fights our geometry until the stack
        // overflows (reproduced under LLDB). Keep both the accessory and fullscreen layout until
        // the transition finishes; a positioningTrafficLights reentry guard alone cannot stop it.
        exiting = true
        reveal?.onChange = nil
        cancelEscape()
    }

    func didExit() {
        if let r = reveal, let i = c.window.titlebarAccessoryViewControllers.firstIndex(of: r) {
            c.window.removeTitlebarAccessoryViewController(at: i)
        }
        reveal = nil
        c.isFullscreen = false
        exiting = false
        titlebarRevealed = false
        updateHeader(animated: false)
        c.positionTrafficLights()
    }

    /// AppKit gave up entering (the window stays windowed): back to the windowed layout.
    func didFailToEnter() {
        exiting = false
        c.isFullscreen = false
        titlebarRevealed = false
        updateHeader(animated: false)
        c.positionTrafficLights()
    }

    /// AppKit gave up leaving (the window stays in full screen): Esc and the menu-bar reveal work again.
    func didFailToExit() {
        exiting = false
        reveal?.onChange = { [weak self] amount in self?.revealChanged(amount) }
    }

    // MARK: The titlebar coming down with the menu bar

    /// `amount`: how far the full-screen titlebar is down, 0 (up, out of sight) to 1.
    func revealChanged(_ amount: Double) {
        guard !exiting else { return }
        let revealed = c.isFullscreen && amount > 0.01
        guard revealed != titlebarRevealed else { return }
        titlebarRevealed = revealed
        updateHeader(animated: true)
    }

    /// The toggle sits at the very left in full screen (Arc), or right of the traffic lights while they show.
    private func updateHeader(animated: Bool) {
        let header = c.sidebar.header
        let wanted = c.isFullscreen && !titlebarRevealed
        guard header.fullscreen != wanted else { return }
        guard animated else { header.fullscreen = wanted; return }
        let curve = AircCurve.folderOpen
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = curve.duration
            ctx.timingFunction = curve.timingFunction
            ctx.allowsImplicitAnimation = true
            header.fullscreen = wanted
            header.layoutSubtreeIfNeeded()
        }
    }

    // MARK: Esc

    /// A key-down of Esc with no modifiers in this window. True when it was used here (the page doesn't get it).
    func escapeDown(_ event: NSEvent) -> Bool {
        guard c.isFullscreen, !exiting, escapeIsFree else {
            cancelEscape()
            return false
        }
        if let seen = lastEscapeSeen, event.timestamp <= seen { return false }
        lastEscapeSeen = event.timestamp
        // Held: the key repeats stay here while the hold runs out.
        if event.isARepeat { return escapeHold != nil }
        if let last = lastEscape, event.timestamp - last <= Self.doublePress {
            cancelEscape()
            exit()
            return true
        }
        lastEscape = event.timestamp
        escapeHold?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.cancelEscape()
            self?.exit()
        }
        escapeHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: work)
        // With no page or field focused it would go straight to AppKit, which leaves full screen on it.
        return c.window.firstResponder === c.window
    }

    func escapeUp() {
        escapeHold?.cancel()
        escapeHold = nil
    }

    private func cancelEscape() {
        escapeHold?.cancel()
        escapeHold = nil
        lastEscape = nil
    }

    /// Esc isn't someone else's: no Airc overlay that closes on it is open and no text is being edited.
    private var escapeIsFree: Bool {
        c.commandBar == nil && c.findBar == nil && c.newSpacePanel == nil && c.createProfilePanel == nil
            && c.pendingExtensionReview == nil && !(c.window.firstResponder is NSTextView)
    }

    /// Leaves full screen. Never enters it: a request while the window isn't in full screen only counts.
    func exit() {
        exitRequests += 1
        guard !exiting, c.window.styleMask.contains(.fullScreen) else { return }
        c.window.toggleFullScreen(nil)
    }
}

/// Learns how far the full-screen titlebar is down. AppKit sets each titlebar accessory's private `revealAmount`
/// (0 up … 1 down) as the titlebar slides with the menu bar; Chromium's immersive full screen relies on the same call
/// (components/remote_cocoa/app_shim/immersive_mode_controller_cocoa.mm). Added only while in full screen.
final class FullScreenRevealAccessory: NSTitlebarAccessoryViewController {
    var onChange: ((Double) -> Void)?

    private typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
    private static let setter = NSSelectorFromString("setRevealAmount:")
    /// NSTitlebarAccessoryViewController's own setter, which the titlebar's layout depends on.
    private static let superSetter: Setter? = class_getInstanceMethod(NSTitlebarAccessoryViewController.self, setter)
        .map { unsafeBitCast(method_getImplementation($0), to: Setter.self) }

    override func loadView() {
        // A 1 pt strip under the titlebar: it is only on screen while the titlebar is down (fullScreenMinHeight 0).
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    @objc(setRevealAmount:) func setRevealAmount(_ amount: Double) {
        Self.superSetter?(self, Self.setter, amount)
        onChange?(amount)
    }
}

/// View → Enter Full Screen / Exit Full Screen. The item has no target, like Chrome's: the window toggles itself. On
/// macOS 26 AppKit puts its own copy of it above, with 🌐F, and hides this one, which keeps answering ⌃⌘F. The View
/// menu's delegate titles both for the browser window's state each time the menu opens.
final class FullScreenMenu: NSObject, NSMenuDelegate {
    static let shared = FullScreenMenu()
    static let action = #selector(NSWindow.toggleFullScreen(_:))

    static func item() -> NSMenuItem {
        let item = NSMenuItem(title: "Enter Full Screen", action: action, keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.command, .control]
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let window = (NSApp.delegate as? AppDelegate)?.controller?.window ?? NSApp.mainWindow
        let full = window?.styleMask.contains(.fullScreen) == true
        for item in menu.items where item.action == Self.action {
            item.title = full ? "Exit Full Screen" : "Enter Full Screen"
        }
    }
}
