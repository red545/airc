// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit

// Offscreen captures that match the screen (design pass 4; docs/qa/visual-review.md #5).
//
// On macOS 26 a label `NSTextField` draws its text through a private `NSTextFieldSimpleLabel` subview. On screen only
// that subview's backing store shows, so the text is composited once. `cacheDisplay(in:to:)` and
// `CALayer.render(in:)` draw the subview's backing store *and* ask the text field itself to draw, so every label in
// the capture is composited twice: ink at alpha a comes out at 1 − (1 − a)², e.g. 0.60 → 0.84, 0.86 → 0.98. Fills,
// SwiftUI text, `NSTextView`, `CATextLayer` and custom `draw(_:)` text are unaffected. `AircSnapshot` hides those
// private subviews while it captures, so each label is drawn once (by its own cell), and restores them.

@MainActor
public enum AircSnapshot {
    /// Class names of private views that duplicate their parent's drawing in an offscreen capture.
    public static let duplicatingViewClasses: Set<String> = ["NSTextFieldSimpleLabel"]

    /// Renders `view` (and its subviews) like the screen shows it, at the window's backing scale.
    public static func bitmap(of view: NSView, in rect: NSRect? = nil) -> NSBitmapImageRep? {
        let r = rect ?? view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: r) else { return nil }
        withoutDuplicates(in: view) { view.cacheDisplay(in: r, to: rep) }
        return rep
    }

    /// The same as an `NSImage` sized in points.
    public static func image(of view: NSView, in rect: NSRect? = nil) -> NSImage? {
        guard let rep = bitmap(of: view, in: rect) else { return nil }
        let img = NSImage(size: (rect ?? view.bounds).size)
        img.addRepresentation(rep)
        return img
    }

    /// Runs `body` with the duplicating private subviews of `root` hidden, then restores them. Use it around your own
    /// `cacheDisplay` or `CALayer.render(in:)` calls.
    public static func withoutDuplicates<T>(in root: NSView, _ body: () throws -> T) rethrows -> T {
        var hidden: [NSView] = []
        func walk(_ v: NSView) {
            for s in v.subviews {
                if !s.isHidden, duplicatingViewClasses.contains(String(describing: type(of: s))) {
                    s.isHidden = true
                    hidden.append(s)
                } else {
                    walk(s)
                }
            }
        }
        walk(root)
        defer { hidden.forEach { $0.isHidden = false } }
        return try body()
    }
}
