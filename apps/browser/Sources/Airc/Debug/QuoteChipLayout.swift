// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AppKit

/// sidebarchrome (owner 2026-11-20): Share Quote lives inside the address pill, so nothing below the pill moves. The
/// checks (quotecopy, paritysmallgaps) measure the sidebar's content before and after the chip shows.
extension SnapshotRunner {
    /// One synthetic Favorite and one synthetic pinned tab in the current Space (made-up example.com pages, never
    /// loaded), so the first Favorite and the first pinned row exist to be measured.
    func quoteChipFixtureRows() {
        run { [self] in
            let space = c.currentSpaceID
            let profile = c.store.profile(ofSpace: space).id
            if c.store.favorites(ofProfile: profile).isEmpty {
                try? favorite("https://example.com/", title: "Example Favorite", icon: nil, profile: profile, space: space)
            }
            if c.store.pinnedRows(ofSpace: space).isEmpty {
                try? pin("https://example.org/notes", title: "Example Pinned", icon: nil, space: space)
            }
        }
        wait(0.5)
    }

    /// Where the sidebar's content is, in window points: the first Favorite, the first pinned row, the Space's list,
    /// the address pill, and the presentation (on-screen) position of the first two, which an animation would move.
    func quoteChipLayout() -> [(String, NSRect)] {
        c.root.layoutSubtreeIfNeeded()
        guard let pv = c.pageView(for: c.currentSpaceID) else { return [] }
        let space = c.currentSpaceID
        let profile = c.store.profile(ofSpace: space).id
        func win(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }
        func shown(_ v: NSView) -> NSRect {
            guard let l = v.layer, let p = l.presentation() else { return win(v) }
            let dx = p.position.x - l.position.x, dy = p.position.y - l.position.y
            return win(v).offsetBy(dx: dx, dy: v.superview?.isFlipped == true ? -dy : dy)
        }
        var out: [(String, NSRect)] = []
        if let f = c.store.favorites(ofProfile: profile).first, let v = pv.tileView(f.id) {
            out += [("first Favorite", win(v)), ("first Favorite on screen", shown(v))]
        }
        if let r = c.store.pinnedRows(ofSpace: space).first, let v = pv.rows[r.id] {
            out += [("first pinned row", win(v)), ("first pinned row on screen", shown(v))]
        }
        out += [("Space list", win(pv.scrollView)), ("Space name", win(pv.header)), ("address pill", win(pv.urlField)),
                ("pager", win(c.sidebar.pager))]
        return out
    }

    /// The differences between two measurements ("" when nothing moved by even a pixel).
    func quoteChipShift(_ a: [(String, NSRect)], _ b: [(String, NSRect)]) -> String {
        let scale = c.window.backingScaleFactor
        let moved = zip(a, b).compactMap { x, y -> String? in
            let px = { (r: NSRect) in NSRect(x: (r.minX * scale).rounded(), y: (r.minY * scale).rounded(),
                                              width: (r.width * scale).rounded(), height: (r.height * scale).rounded()) }
            return px(x.1) == px(y.1) ? nil : "\(x.0) \(NSStringFromRect(x.1)) → \(NSStringFromRect(y.1))"
        }
        return a.count == b.count ? moved.joined(separator: "; ") : "measured \(a.count) vs \(b.count) things"
    }

    /// The chip sits inside the current Space's address pill, at its right end, vertically centred.
    func quoteChipPlacement(_ p: QuotePillView) -> (ok: Bool, why: String) {
        guard let pv = c.pageView(for: c.currentSpaceID) else { return (false, "no page view") }
        let f = pv.urlField
        let r = p.frame
        let ok = p.superview === f && abs(r.midY - f.bounds.midY) < 0.5 && abs(f.bounds.maxX - QuotePillView.inset - r.maxX) < 0.5
            && r.minX > 40 && r.height == QuotePillView.height
        return (ok, "chip \(NSStringFromRect(r)) in pill \(NSStringFromRect(f.bounds)), in it: \(p.superview === f)")
    }
}
#endif
