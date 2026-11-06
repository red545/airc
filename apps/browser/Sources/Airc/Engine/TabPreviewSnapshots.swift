// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import WebKit
#if canImport(AircCore)
import AircCore
#endif

/// Tab previews (Sidebar/TabPreview.swift): a small picture of a page as it is on screen now, for the card beside a
/// sidebar row. Only ever asked of a page that is on screen; the app keeps the last picture of every other tab itself
/// (TabPreviewCache), so a hidden page is never woken or repainted for it.
protocol EnginePreviewSnapshotting: AnyObject {
    /// At most `maxPixels` (aspect kept, never upscaled); nil when the page has no frame to copy.
    func previewSnapshot(maxPixels: CGSize, completion: @escaping (CGImage?) -> Void)
    /// A picture asked for just before the page is hidden still comes. Chromium's copy waits for the surface's next
    /// frame, which a hidden page never draws (nil after 500 ms), so its pages are pictured while shown instead.
    var picturesLeavingPage: Bool { get }
}

extension WebKitTab: EnginePreviewSnapshotting {
    var picturesLeavingPage: Bool { true }

    /// `takeSnapshot` without waiting for a screen update, so it never asks the page for a new frame. A page off screen
    /// (detached or hidden) isn't asked at all: WebKit would paint it in its web process just for this.
    func previewSnapshot(maxPixels: CGSize, completion: @escaping (CGImage?) -> Void) {
        guard webView.window != nil, !webView.isHiddenOrHasHiddenAncestor, webView.bounds.width > 1, webView.bounds.height > 1,
              maxPixels.width >= 1, maxPixels.height >= 1 else { return completion(nil) }
        let scale = webView.window?.backingScaleFactor ?? 2
        let fit = min(maxPixels.width / (webView.bounds.width * scale), maxPixels.height / (webView.bounds.height * scale), 1)
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        // In points; the image comes back at the window's scale.
        config.snapshotWidth = NSNumber(value: Double(webView.bounds.width * fit))
        webView.takeSnapshot(with: config) { image, _ in
            var r = NSRect(origin: .zero, size: image?.size ?? .zero)
            completion(image?.cgImage(forProposedRect: &r, context: nil, hints: nil))
        }
    }
}

#if canImport(AircCore)
extension ChromiumTab: EnginePreviewSnapshotting {
    /// Engine pass "APIs" (engine/PASS-APIS.md): a copy of the compositor surface, resized off the main thread. A
    /// framework from before it lacks the call: no picture, the card shows the placeholder.
    private static let snapshotSelector = #selector(AircTab.snapshot(withMaxSize:completion:))

    var picturesLeavingPage: Bool { false }

    func previewSnapshot(maxPixels: CGSize, completion: @escaping (CGImage?) -> Void) {
        guard core.responds(to: Self.snapshotSelector) else { return completion(nil) }
        core.snapshot(withMaxSize: maxPixels) { image in
            var r = NSRect(origin: .zero, size: image?.size ?? .zero)
            completion(image?.cgImage(forProposedRect: &r, context: nil, hints: nil))
        }
    }
}
#endif
