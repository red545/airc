// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit

/// Scrolls the Settings page for a marketing shot, so the section a shot is about is in the frame as pages grow.
extension SnapshotRunner {
    enum MkSettingsScroll { case down(CGFloat), end }

    func mkScrollSettings(_ how: MkSettingsScroll) {
        guard let view = c.app?.settingsWindow?.window.contentView else { return }
        // The page's scroll view: the taller document (the sidebar has none of its own).
        var scrolls: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { scrolls.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        guard let s = scrolls.max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }),
              let doc = s.documentView else { return note("marketing: no Settings scroll view") }
        let room = max(0, doc.bounds.height - s.contentView.bounds.height)
        let down: CGFloat
        switch how {
        case .down(let points): down = min(room, points)
        case .end: down = room
        }
        s.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? down : room - down))
        s.reflectScrolledClipView(s.contentView)
    }
}
#endif
