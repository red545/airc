// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Dispatch
import Foundation

/// Renders and caches Space backgrounds off the main thread, so a Space switch only swaps a layer's contents.
///
/// The colour layer depends only on the theme and the window's aspect ratio (it is at most 200 px and scaled by
/// Core Animation), so one image per theme and aspect bucket serves every window of that shape. Rendering one costs
/// 1–3 ms; a cache hit costs nothing. Thread-safe.
///
/// ```swift
/// // When the window opens or resizes, warm every Space's background in the background:
/// AircBackgroundCache.shared.prerender(spaces.map { $0.resolved }, size: window.frame.size)
/// // On a switch, the view finds it in the cache; or hand it over explicitly:
/// let image = AircBackgroundCache.shared.colorLayer(for: next, size: bounds.size)   // any thread
/// background.setTheme(next, colorLayer: image, animated: true)
/// ```
public final class AircBackgroundCache: @unchecked Sendable {
    public static let shared = AircBackgroundCache()

    /// Most images kept (themes × window shapes). Each is ≤ 200 × 200 px (160 KB).
    public var capacity = 48

    private struct Key: Hashable {
        let theme: ResolvedTheme
        let aspect: Int
    }

    private let lock = NSLock()
    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let queue = DispatchQueue(label: "airc.background-render", qos: .userInitiated, attributes: .concurrent)

    public init() {}

    /// The aspect bucket (2 % steps, the same tolerance `SpaceBackgroundView` re-renders at).
    static func bucket(_ size: CGSize) -> Int {
        let aspect = size.height > 0 ? size.width / size.height : 1
        return Int((aspect / 0.02).rounded())
    }

    /// The cached colour layer, or nil. Never renders.
    public func cachedColorLayer(for theme: ResolvedTheme, size: CGSize) -> CGImage? {
        let key = Key(theme: theme, aspect: Self.bucket(size))
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    /// The colour layer (`ResolvedTheme.colorLayerImage(for:)`), from the cache or rendered now on the calling
    /// thread. Safe to call from any thread.
    public func colorLayer(for theme: ResolvedTheme, size: CGSize) -> CGImage {
        if let hit = cachedColorLayer(for: theme, size: size) { return hit }
        let image = theme.colorLayerImage(for: size)
        store(image, for: Key(theme: theme, aspect: Self.bucket(size)))
        return image
    }

    /// Renders the given themes' colour layers on a background queue. `completion` runs on the main queue.
    public func prerender(_ themes: [ResolvedTheme], size: CGSize, completion: (@Sendable () -> Void)? = nil) {
        let group = DispatchGroup()
        for theme in Set(themes) where cachedColorLayer(for: theme, size: size) == nil {
            queue.async(group: group) { _ = self.colorLayer(for: theme, size: size) }
        }
        if let completion { group.notify(queue: .main, execute: completion) }
    }

    /// Renders the given themes off the main thread and returns when they are cached.
    public func prerenderAndWait(_ themes: [ResolvedTheme], size: CGSize) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            prerender(themes, size: size) { c.resume() }
        }
    }

    public func removeAll() {
        lock.lock()
        images = [:]
        order = []
        lock.unlock()
    }

    private func store(_ image: CGImage, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if images[key] == nil { order.append(key) }
        images[key] = image
        while order.count > capacity { images[order.removeFirst()] = nil }
    }
}
