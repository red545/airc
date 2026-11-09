// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// One presentation for the engine overlay and the app's call fallback. Only the floating window is resized;
/// the page and its tracks stay alive. The opaque pill covers the video while collapsed.
final class MiniPlayerPresentation: NSObject {
    weak var controls: PiPControlsView?
    weak var playbackPage: EngineTab?
    private(set) var isWindowHidden = false
    private(set) var state = MiniPlayerState()
    private var expandingTo: NSRect?
    private var minimum = NSSize.zero
    private var aspect = NSSize.zero
    private var videoAspect: CGFloat?
    private var monitor: Any?
    private lazy var animator = FrameAnimator(view: controls ?? pill)
    let pill = NSView()
    let title = PiPButton(symbol: "arrow.up.left.and.arrow.down.right", size: 11, style: .pill, label: "Expand Mini Player")
    let play = PiPButton(symbol: "play.fill", size: 15, style: .bare, label: "Play")

    init(_ controls: PiPControlsView) {
        self.controls = controls
        super.init()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        pill.addSubview(title)
        pill.addSubview(play)
        pill.isHidden = true
        controls.addSubview(pill)
        title.action = { [weak self] in self?.setMinimized(false) }
        play.action = { [weak controls] in controls?.actions.playPause() }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// The minus button hides the window, never the media, tracks or page.
    func hideWindow() {
        guard let page = playbackPage, let window = controls?.window, !page.isClosed else { return }
        setMinimized(false, animated: false)
        isWindowHidden = true
        HiddenMiniPlayers.remember(page, self)
        window.orderOut(nil)
    }

    func restoreWindow() {
        guard isWindowHidden, let window = controls?.window else { return }
        isWindowHidden = false
        window.orderFront(nil) // restore without activating or taking keyboard focus
        controls?.flashControls()
    }

    func clearHiddenWindow() { isWindowHidden = false }

    func attach() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard controls?.window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, let c = self.controls, let window = c.window, event.window === window else { return event }
            let onChrome = self.handlesPointer(at: event.locationInWindow)
            if event.type == .rightMouseDown, onChrome {
                NSMenu.popUpContextMenu(self.contextMenu(), with: event, for: c)
                return nil
            }
            if event.type == .leftMouseDown, onChrome { window.makeFirstResponder(c) }
            if event.type == .keyDown, window.firstResponder === c,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if event.keyCode == 53 { self.setMinimized(true); return nil }
                if event.keyCode == 49, c.state.canPlayPause, !c.state.call { c.actions.playPause(); return nil }
            }
            return event
        }
    }

    func handlesPointer(at point: NSPoint) -> Bool {
        guard let c = controls else { return false }
        if state.isMinimized { return c.bounds.contains(c.convert(point, from: nil)) }
        return c.hitTest(c.superview?.convert(point, from: nil) ?? point) != nil
    }

    func update() {
        guard let c = controls else { return }
        title.title = c.mediaTitle.isEmpty ? "Mini Player" : c.mediaTitle
        play.symbol = c.state.playing ? "pause.fill" : "play.fill"
        play.label = c.state.playing ? "Pause" : "Play"
        play.isHidden = c.state.call || !c.state.canPlayPause
        pill.frame = c.bounds
        title.frame = NSRect(x: 8, y: 6, width: c.bounds.width - (play.isHidden ? 16 : 52), height: 36)
        play.frame = NSRect(x: c.bounds.width - 44, y: 6, width: 36, height: 36)
        c.content.isHidden = state.isMinimized
        pill.isHidden = !state.isMinimized
    }

    /// A source can change while the pill has hidden the video (an ad, then the film). The engine refits
    /// its window, but expansion must not overwrite that with the previous video's saved rectangle.
    func videoSourceChanged(width: Double, height: Double) {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        videoAspect = CGFloat(width / height)
        if let destination = expandingTo, let window = controls?.window {
            animator.cancel("miniPlayer")
            window.setFrame(fittingVideo(destination, in: window), display: true)
            window.minSize = minimum
            window.contentAspectRatio = aspect
            expandingTo = nil
        }
    }

    private func fittingVideo(_ frame: NSRect, in window: NSWindow) -> NSRect {
        guard let ratio = videoAspect, ratio.isFinite, ratio > 0 else { return frame }
        var size = NSSize(width: sqrt(frame.width * frame.height * ratio), height: sqrt(frame.width * frame.height / ratio))
        let screen = window.screen?.visibleFrame
        if let screen {
            let scale = min(1, min(screen.width / max(1, size.width), screen.height / max(1, size.height)))
            size.width *= scale; size.height *= scale
        }
        var result = NSRect(x: frame.maxX - size.width, y: frame.minY, width: size.width, height: size.height)
        if let screen {
            result.origin.x = max(screen.minX, min(result.minX, screen.maxX - size.width))
            result.origin.y = max(screen.minY, min(result.minY, screen.maxY - size.height))
        }
        return result
    }

    func setMinimized(_ minimized: Bool, animated: Bool = true) {
        guard let c = controls, let window = c.window, state.isMinimized != minimized else { return }
        animator.cancel("miniPlayer")
        let from = window.frame
        let target: NSRect
        if minimized {
            // Reversing an expansion must keep its destination, not the partially drawn pill.
            state.minimize(from: expandingTo ?? from)
            if expandingTo == nil { minimum = window.minSize; aspect = window.contentAspectRatio }
            expandingTo = nil
            window.minSize = NSSize(width: 260, height: 48)
            window.contentAspectRatio = .zero
            target = NSRect(x: from.maxX - 260, y: from.minY, width: 260, height: 48)
        } else {
            target = fittingVideo(state.expand() ?? from, in: window)
            expandingTo = target
        }
        update()
        let finish = { [weak self, weak window] in
            guard let self, let window else { return }
            window.setFrame(target, display: true)
            if !minimized { window.minSize = self.minimum; window.contentAspectRatio = self.aspect; self.expandingTo = nil }
            self.controls?.flashControls()
        }
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { finish(); return }
        animator.spring("miniPlayer", from: 0, to: 1, spring: Spring(response: 0.32, dampingRatio: 1), update: { [weak window] t in
            window?.setFrame(NSRect(x: from.minX + (target.minX - from.minX) * t, y: from.minY + (target.minY - from.minY) * t,
                                   width: from.width + (target.width - from.width) * t, height: from.height + (target.height - from.height) * t), display: true)
        }, completion: finish)
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let actions: [(String, String)] = [("Back to Tab", "back"), (controls?.state.muted == true ? "Unmute" : "Mute", "mute"),
            ("Picture in Picture", "pip"), ("Close", "close"), ("Don’t Show for This Site", "never")]
        for (title, id) in actions {
            if id == "never", controls?.canSuppressSite != true { continue }
            let item = NSMenuItem(title: title, action: #selector(performMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.isEnabled = id != "never" || controls?.canSuppressSite == true
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    @objc func performMenu(_ item: NSMenuItem) {
        guard let c = controls, let id = item.representedObject as? String else { return }
        switch id {
        case "back": setMinimized(false, animated: false); c.actions.backToTab()
        case "mute": c.actions.mute()
        case "pip": setMinimized(false, animated: false); c.actions.pictureInPicture()
        case "close": setMinimized(false, animated: false); if !c.state.call { c.actions.stopPlayback() }; c.actions.close()
        case "never": guard c.canSuppressSite else { return }; setMinimized(false, animated: false); c.actions.suppressSite()
        default: break
        }
    }
}
