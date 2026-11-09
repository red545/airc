// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// W03 (Arc ref §2.10): with the sidebar hidden, holding ⌥ on its own slides the floating sidebar out
/// (SidebarRevealController, the same panel the window's edge reveals), and letting go slides it back, unless the pointer
/// went into it meanwhile, in which case it stays as an edge reveal does. Anything that makes ⌥ part of something else
/// cancels it: another key (⌥ types @ [ ] { } | ~ on Austrian and German keyboards), another modifier (⌥⌘ shortcuts), a
/// click (⌥-click splits) or a scroll. While text is being edited (a page's field or ours) ⌥ belongs to the text (⌥← ⌥→
/// move by word), so nothing shows. Settings → Shortcuts can turn it off (SidebarNavigationPreferences.optionRevealsSidebar).
final class OptionReveal {
    static let shared = OptionReveal()

    /// ⌥ must be held this long, alone, before anything moves: typing an ⌥ character never flashes the sidebar.
    static let holdDelay: TimeInterval = 0.2

    enum Phase: Equatable {
        case idle
        /// ⌥ went down alone; the reveal waits for `holdDelay`.
        case holding
        /// The sidebar is out because of ⌥.
        case revealed
        /// ⌥ became part of a chord: nothing more until it's released.
        case cancelled
    }

    private(set) var phase: Phase = .idle
    private var monitor: Any?
    private var pending: DispatchWorkItem?
    private weak var controller: WindowController?
    #if AIRC_TESTING
    /// ParityP03Check: each reveal and hide this made, in order ("reveal", "hide", "keep", "cancel").
    private(set) var log: [String] = []
    func clearLog() { log = [] }
    /// The check can't hold the real key: the window to use when the event's own isn't the key window.
    var testWindowController: WindowController?
    /// The check's stand-in for where the pointer is (the real one is the owner's).
    var testPointerInPanel: Bool?
    #endif

    private func note(_ s: String) {
        #if AIRC_TESTING
        log.append(s)
        #endif
    }

    /// Once per app (the first sidebar page installs it).
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] e in
            self?.handle(e)
            return e
        }
    }

    func handle(_ e: NSEvent) {
        switch e.type {
        case .flagsChanged:
            TabSwitcher.modifiersChanged(e.modifierFlags)
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if mods == .option {
                if phase == .idle { begin(e) }
            } else if mods.contains(.option) {
                // ⌥ with another modifier: a shortcut, not a reveal.
                cancel(hide: true)
            } else {
                released()
            }
        case .keyDown, .scrollWheel:
            if phase == .holding || phase == .revealed { cancel(hide: true) }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard phase == .holding || phase == .revealed else { return }
            // A click in the revealed sidebar keeps it (the pointer is there now); anywhere else ends it.
            cancel(hide: !pointerIsInPanel(e))
        default: break
        }
    }

    private func begin(_ e: NSEvent) {
        guard let c = windowController(for: e), Self.canReveal(c) else { return }
        controller = c
        phase = .holding
        let work = DispatchWorkItem { [weak self] in self?.holdEnded() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    private func holdEnded() {
        pending = nil
        guard phase == .holding, let c = controller, Self.canReveal(c) else { phase = phase == .holding ? .idle : phase; return }
        c.revealController?.reveal()
        phase = .revealed
        note("reveal")
    }

    private func released() {
        pending?.cancel()
        pending = nil
        if phase == .revealed, let c = controller {
            if Self.pointerIsInPanel(of: c) || keyboardIsInSidebar(c) {
                // The pointer (or the keyboard) went into it: it stays, and leaves as an edge reveal does.
                note("keep")
            } else {
                c.revealController?.hide()
                note("hide")
            }
        }
        phase = .idle
        controller = nil
    }

    private func cancel(hide: Bool) {
        pending?.cancel()
        pending = nil
        if phase == .revealed, let c = controller {
            if hide, !Self.pointerIsInPanel(of: c), !keyboardIsInSidebar(c) { c.revealController?.hide(); note("hide") } else { note("keep") }
        }
        if phase != .idle { note("cancel") }
        phase = phase == .idle ? .idle : .cancelled
    }

    /// The setting is on, the sidebar is hidden and not out already, no text is being edited, the window is the key one,
    /// and nothing modal is up.
    static func canReveal(_ c: WindowController) -> Bool {
        guard SidebarNavigation.preferences.optionRevealsSidebar, c.sidebarHidden, c.sidebarFraction <= 0.001,
              c.revealController?.isRevealed != true, c.window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(c.window.firstResponder is NSTextView), !KeyMonitor.pageIsEditingText(c) else { return false }
        #if AIRC_TESTING
        if shared.testWindowController === c { return true }
        #endif
        return c.window.isKeyWindow
    }

    private func windowController(for e: NSEvent) -> WindowController? {
        #if AIRC_TESTING
        if let t = testWindowController { return t }
        #endif
        guard let app = NSApp.delegate as? AppDelegate else { return nil }
        return app.controller(for: e.window ?? NSApp.keyWindow)
    }

    private func pointerIsInPanel(_ e: NSEvent) -> Bool {
        #if AIRC_TESTING
        if let t = testPointerInPanel { return t }
        #endif
        guard let c = controller, e.window === c.window, let panel = c.sidebar.superview, panel !== c.root else { return false }
        return panel.frame.contains(c.root.convert(e.locationInWindow, from: nil))
    }

    static func pointerIsInPanel(of c: WindowController) -> Bool {
        #if AIRC_TESTING
        if let t = shared.testPointerInPanel { return t }
        #endif
        guard let panel = c.sidebar.superview, panel !== c.root, c.revealController?.isRevealed == true else { return false }
        let p = c.root.convert(c.window.mouseLocationOutsideOfEventStream, from: nil)
        return panel.frame.insetBy(dx: -AircMetrics.Sidebar.floatingKeepAlive, dy: 0).contains(p)
    }

    private func keyboardIsInSidebar(_ c: WindowController) -> Bool {
        (c.window.firstResponder as? SidebarRowView)?.page?.keyboardActive == true
    }
}
