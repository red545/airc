// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// The theme picker (TH-1; design.md §7 "Theme picker", visual review #4): AircDesign's `AircThemePicker`, 357 × 509,
/// dressed in the theme being edited, in a borderless panel beside its anchor. The picker draws its own 20 pt panel and
/// shadow, so it isn't put in an NSPopover, whose chrome would frame it twice. A click elsewhere or Esc closes it;
/// every change recolours the window live through `onChange`.
final class ThemePickerPanel {
    /// Room around the picker for its shadow.
    static let margin: CGFloat = 24

    let window: NSPanel
    private weak var parent: NSWindow?
    private var monitor: Any?
    var isShown: Bool { window.isVisible }
    var contentView: NSView? { window.contentView }

    init(theme: SpaceTheme, systemIsDark: Bool, onChange: @escaping (SpaceTheme) -> Void) {
        let size = AircMetrics.ThemePicker.size
        let m = Self.margin
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size.width + 2 * m, height: size.height + 2 * m),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = true
        window.animationBehavior = .none
        let editor = ThemeEditor(theme: theme.design, systemIsDark: systemIsDark) { onChange($0.model) }
        window.contentView = AircFirstClickHostingView(rootView: AnyView(editor.padding(m)))
    }

    /// Shows the picker to the right of `rect` in `view` (the sidebar's edge), its top level with the anchor's and
    /// kept inside the window.
    func show(relativeTo rect: NSRect, of view: NSView) {
        guard let parent = view.window else { return }
        self.parent = parent
        let m = Self.margin
        let anchor = parent.convertToScreen(view.convert(rect, to: nil))
        let size = window.frame.size
        let edge = AircMetrics.ThemePicker.edgeOffset
        var top = min(anchor.maxY, parent.frame.maxY - edge) + m
        let bottom = top - size.height
        if bottom < parent.frame.minY + edge - m { top += (parent.frame.minY + edge - m) - bottom }
        window.setFrameTopLeftPoint(NSPoint(x: anchor.maxX + edge - m, y: top))
        window.alphaValue = 0
        parent.addChildWindow(window, ordered: .above)
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AircCurve.previewIn.duration
            window.animator().alphaValue = 1
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown {
                guard e.keyCode == 53 else { return e }
                self.close()
                return nil
            }
            if e.window !== self.window { self.close() }
            return e
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        parent?.removeChildWindow(window)
        window.orderOut(nil)
    }
}

/// Holds the edited theme for AircThemePicker and reports each change.
private struct ThemeEditor: View {
    @State var theme: DesignTheme
    let systemIsDark: Bool
    let onChange: (DesignTheme) -> Void

    var body: some View {
        AircThemePicker(theme: $theme, systemIsDark: systemIsDark)
            .onChange(of: theme) { _, t in onChange(t) }
    }
}
