// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

#if canImport(AircCore)
import AircCore

// chrome.action.openPopup() (and browserAction.openPopup): an extension asks for its own popup, e.g. 1Password's
// "Unlock 1Password" button on its in-page card. Chromium checks the window is active and the extension has a popup on
// its active tab, then asks the host (engine/core/airc_extension_view.mm, OpenActionPopup); the app shows the popup
// under the extension's button (Extensions.swift) and the engine answers the call once its page has loaded (10 s).
//
// As in Chrome, opening the popup this way doesn't perform the action: no activeTab grant on the shown page (the
// button's click path, presentExtensionAction, runs the action and does grant it).
//
// Both paths use the same app-owned panel (ExtensionPopupPanel), which follows the popup page's own size: the engine's
// panel (presentActionPopup) kept the size it opened with (360 × 480 before the page loaded), so a wider popup such as
// Proton Pass's (600 × 430) was cut off and scrolled.
extension ChromiumEngine {
    /// The extension's popup for `tab`'s page, anchored on `anchorRect` of `view`; `align` places the panel (and runs
    /// again when the popup's page changes its size). `performAction`: the button's click (runs the action, granting
    /// activeTab); else chrome.action.openPopup's (no grant). False: no popup to show (an action without one ran).
    @discardableResult
    func presentExtensionPopup(_ id: String, for tab: EngineTab, anchorRect: NSRect, in view: NSView,
                               performAction: Bool = false, align: @escaping (NSPanel) -> Void) -> Bool {
        guard let tab = tab as? ChromiumTab, !tab.isClosed, let owner = tab.owner, view.window === owner.window,
              let profile = tab.core.profile else { return false }
        // A click on the button of the popup that click just closed (the panel closes on any click outside it): Chrome's
        // toggle, the popup stays closed.
        if performAction, ExtensionPopupPanel.closedByClick(id) { return false }
        closeExtensionPopup(in: owner)
        let popup: AircTab?
        if performAction {
            popup = owner.core.openActionPopup(extensionID: id, tab: tab.core)
        } else {
            guard let url = tab.core.actionStates(forExtensions: [id])[id]?["popup"] as? String, !url.isEmpty else { return false }
            popup = owner.core.openExtensionView(url, profile: profile, kind: "popup")
        }
        guard let popup else { return false }
        ExtensionPopupPanel.present(popup, extensionID: id, over: owner.window, key: ObjectIdentifier(owner.core), align: align)
        return true
    }
}

/// An openPopup popup: a nonactivating panel above its browser window, as the button's (engine/core/airc_host_api.mm),
/// with Chrome's popup behaviour: it takes the keyboard, sizes itself to its page (25…800 × 25…600), and closes on
/// Escape, a click outside it, the page's window.close(), or its window closing.
final class ExtensionPopupPanel: NSObject, NSWindowDelegate, AircTabDelegate {
    private static var open: [ObjectIdentifier: ExtensionPopupPanel] = [:]
    private static var lastClickClose: (id: String, at: Date)?
    /// This extension's popup closed for a click outside it in the last moment (that click may be on its button).
    static func closedByClick(_ id: String) -> Bool {
        guard let last = lastClickClose, last.id == id, Date().timeIntervalSince(last.at) < 0.4 else { return false }
        lastClickClose = nil
        return true
    }
    let panel: NSPanel
    let extensionID: String
    private(set) var popup: AircTab?
    private let key: ObjectIdentifier
    private let align: (NSPanel) -> Void
    private var monitor: Any?

    static func present(_ popup: AircTab, extensionID: String, over window: NSWindow, key: ObjectIdentifier,
                        align: @escaping (NSPanel) -> Void) {
        close(key)
        let controller = ExtensionPopupPanel(popup, extensionID: extensionID, key: key, align: align)
        open[key] = controller
        window.addChildWindow(controller.panel, ordered: .above)
        align(controller.panel)
        controller.panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the openPopup popup of the window with this key (`ObjectIdentifier` of its AircWindow).
    static func close(_ key: ObjectIdentifier) { open[key]?.panel.close() }

    /// The shown one for a window, for checks.
    static func shown(_ key: ObjectIdentifier) -> ExtensionPopupPanel? { open[key] }

    private init(_ popup: AircTab, extensionID: String, key: ObjectIdentifier, align: @escaping (NSPanel) -> Void) {
        self.popup = popup
        self.extensionID = extensionID
        self.key = key
        self.align = align
        var size = popup.preferredSize
        if size.width < 25 || size.height < 25 { size = NSSize(width: 360, height: 480) }
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.clamp(size)),
                        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Extension"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        popup.delegate = self
        popup.attach(to: panel.contentView!)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53, event.window === self.panel { self.panel.close(); return nil } // Escape
            } else if event.window !== self.panel {
                Self.lastClickClose = (self.extensionID, Date())
                self.panel.close()
            }
            return event
        }
    }

    /// Chrome's placement: the content's top at the anchor's bottom; trailing edges together for an anchor in the
    /// window's right half (the toolbar, a sidebar on the right), leading edges otherwise; kept on the window's screen.
    static func align(_ panel: NSWindow, under anchor: NSRect, in window: NSWindow) {
        let content = panel.contentRect(forFrameRect: panel.frame).size
        let trailing = anchor.midX > window.frame.midX
        let x = trailing ? anchor.maxX - content.width : anchor.minX
        var frame = panel.frameRect(forContentRect: NSRect(x: x, y: anchor.minY - content.height, width: content.width, height: content.height))
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(screen.minX, min(frame.origin.x, screen.maxX - frame.width))
            frame.origin.y = max(screen.minY, min(frame.origin.y, screen.maxY - frame.height))
        }
        panel.setFrame(frame, display: false)
    }

    private static func clamp(_ size: NSSize) -> NSSize {
        NSSize(width: min(max(size.width, 25), 800), height: min(max(size.height, 25), 600))
    }

    func tab(_ tab: AircTab, preferredSizeDidChange size: NSSize) {
        guard size.width >= 25, size.height >= 25 else { return }
        let frame = panel.frameRect(forContentRect: NSRect(origin: panel.frame.origin, size: Self.clamp(size)))
        panel.setFrame(frame, display: false)
        align(panel)
    }

    func tabWillClose(_ tab: AircTab) {
        DispatchQueue.main.async { [weak self] in self?.panel.close() }
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.parent?.removeChildWindow(panel)
        let popup = self.popup
        self.popup = nil
        popup?.delegate = nil
        if popup?.closed == false { popup?.close() }
        if Self.open[key] === self { Self.open[key] = nil }
    }
}
#endif
