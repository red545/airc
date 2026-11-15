// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import Testing
@testable import AircDesign

// macOS 26's scroll-edge pocket erases a scroll view's content in offscreen captures (AircSnapshot.erasingViewClasses).
// Settings is a SwiftUI ScrollView in an NSHostingView; its page came out black beside the sidebar on macOS 26.2.

@MainActor
@Suite(.serialized) struct SnapshotPocketTests {
    private struct Pane: View {
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<30) { Text("Row \($0)") }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(red: 0, green: 0, blue: 1))
            .frame(width: 400, height: 300)
        }
    }

    /// The pane's colour at its centre (x 200, y 150 in points), from a capture of the hosting view.
    private func centre(_ rep: NSBitmapImageRep) -> NSColor? {
        rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }

    private func window() -> (NSWindow, NSView) {
        let w = NSWindow(contentRect: NSRect(x: -6000, y: 200, width: 400, height: 300), styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Pane())
        w.contentView = host
        w.orderFront(nil)
        w.setFrameOrigin(NSPoint(x: -6000, y: 200))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return (w, host)
    }

    private func hasPocket(_ v: NSView) -> Bool {
        v.subviews.contains { AircSnapshot.erasingViewClasses.contains(String(describing: type(of: $0))) || hasPocket($0) }
    }

    @Test func scrollViewContentSurvivesTheCapture() {
        let (w, host) = window()
        defer { w.orderOut(nil) }
        let rep = AircSnapshot.bitmap(of: host)!
        let c = centre(rep)
        #expect((c?.alphaComponent ?? 0) > 0.99, "captured pane is transparent: \(String(describing: c))")
        #expect((c?.blueComponent ?? 0) > 0.9, "captured pane lost its background: \(String(describing: c))")
    }

    @Test func pocketIsRestoredAfterTheCapture() {
        let (w, host) = window()
        defer { w.orderOut(nil) }
        func pockets(_ v: NSView) -> [NSView] {
            v.subviews.flatMap { AircSnapshot.erasingViewClasses.contains(String(describing: type(of: $0))) ? [$0] : pockets($0) }
        }
        let before = pockets(host).map(\.isHidden)
        _ = AircSnapshot.bitmap(of: host)
        #expect(pockets(host).map(\.isHidden) == before)
    }

    @Test func plainCacheDisplayErasesThePane() {
        // Documents the cause. If Apple fixes the portal's offscreen rendering, this expectation flips and the
        // pocket can leave AircSnapshot.erasingViewClasses.
        let (w, host) = window()
        defer { w.orderOut(nil) }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let c = centre(rep)
        print("plain cacheDisplay of a SwiftUI ScrollView: centre \(String(describing: c)); pocket present: \(hasPocket(host))")
        if hasPocket(host) {
            #expect((c?.alphaComponent ?? 1) < 0.01)
        }
    }
}
