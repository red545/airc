// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// The last picture of each tab for its preview card (TabPreview.swift), in memory only: never written anywhere, gone
/// at quit. Bounded: the `limit` most recently used pictures, each at most `maxPixels` (about 1 MB), so about 24 MB at
/// most. A picture is kept under its tab and, for a pinned tab or Favorite, under its item too, so a Favorite whose
/// page was freed (SB-15) or closed still shows how it looked. Under memory pressure it keeps the 8 most recent
/// (a warning) or none (critical). Each picture knows its profile: a profile deleted or its browsing data cleared takes
/// its pictures with it (`forget(profileID:)`, ServicePreviewCenter.forget), and a picture is never shown for a tab of
/// another profile. Private windows have no tab previews, so none of their pages is ever kept.
final class TabPreviewCache {
    static let shared = TabPreviewCache()
    static let limit: Int = {
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_PREVIEW_BASELINE"] == "1" { return 40 }
        #endif
        return 24
    }()
    static let maxPixels = CGSize(width: 640, height: 400)
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    private init() {
        pressure.setEventHandler { [weak self] in
            guard let self else { return }
            self.trim(to: self.pressure.data.contains(.critical) ? 0 : 8)
        }
        pressure.activate()
    }

    struct Shot {
        let image: CGImage
        /// The page's address when it was taken: a picture of another site is never shown for this one.
        let url: String
        /// The profile of the tab it was taken in.
        let profileID: String
        let takenAt: CFTimeInterval
    }

    /// Most recently used last.
    private var order: [String] = []
    private var shots: [String: Shot] = [:]

    static func key(tab id: String) -> String { "t:" + id }
    static func key(item id: String) -> String { "i:" + id }

    /// The picture of a tab (or, failing that, of its item) whose page shows `url`, if one is kept (and, given
    /// `profileID`, taken in that profile).
    func shot(tab: String?, item: String?, url: String, profileID: String? = nil) -> Shot? {
        let keys = [tab.map(Self.key(tab:)), item.map(Self.key(item:))].compactMap { $0 }
        for k in keys {
            guard let s = shots[k] else { continue }
            guard Self.sameSite(s.url, url), profileID.map({ $0 == s.profileID }) ?? true else { continue }
            touch(k)
            return s
        }
        return nil
    }

    /// When the tab's picture was taken, without counting as a use.
    func age(tab: String) -> CFTimeInterval? {
        shots[Self.key(tab: tab)].map { CACurrentMediaTime() - $0.takenAt }
    }

    /// `profileID` is the tab's profile; only the checks' synthetic pictures go without one (and so go with the next
    /// sweep, `retain(profiles:)`).
    func store(_ image: CGImage, url: String, tab: String, item: String?, profileID: String = "") {
        let s = Shot(image: image, url: url, profileID: profileID, takenAt: CACurrentMediaTime())
        for k in [Self.key(tab: tab)] + (item.map { [Self.key(item: $0)] } ?? []) {
            shots[k] = s
            touch(k)
        }
        trim(to: Self.limit)
    }

    func removeAll() {
        shots.removeAll()
        order.removeAll()
    }

    /// A profile deleted or its browsing data cleared: its pictures go.
    func forget(profileID: String) {
        for (k, s) in shots where s.profileID == profileID { shots[k] = nil }
        order.removeAll { shots[$0] == nil }
    }

    /// Pictures of profiles that no longer exist go (checked when a card shows, so a deleted profile's pictures never
    /// outlive it for long even without `forget`).
    func retain(profiles: Set<String>) {
        guard shots.values.contains(where: { !profiles.contains($0.profileID) }) else { return }
        for (k, s) in shots where !profiles.contains(s.profileID) { shots[k] = nil }
        order.removeAll { shots[$0] == nil }
    }

    /// The profiles that have pictures kept (the checks).
    var profiles: Set<String> { Set(shots.values.map(\.profileID)) }

    #if AIRC_TESTING
    /// The pages pictured (the checks: never a private window's).
    var urlsForTesting: [String] { shots.values.map(\.url) }
    #endif

    /// Keeps only the `n` most recently used pictures.
    func trim(to n: Int) {
        while order.count > n { shots[order.removeFirst()] = nil }
    }

    var count: Int { shots.count }

    /// Decoded bytes, counting tab/item aliases of the same picture only once.
    var storedBytes: Int {
        var seen = Set<ObjectIdentifier>()
        return shots.values.reduce(0) { bytes, shot in
            guard seen.insert(ObjectIdentifier(shot.image)).inserted else { return bytes }
            return bytes + shot.image.bytesPerRow * shot.image.height
        }
    }

    private func touch(_ k: String) {
        if let i = order.lastIndex(of: k) { order.remove(at: i) }
        order.append(k)
    }

    /// Same host, ignoring "www.": a picture taken before a pinned tab or Favorite wandered elsewhere is not one of
    /// its saved page.
    static func sameSite(_ a: String, _ b: String) -> Bool {
        func host(_ s: String) -> String {
            let h = URL(string: s)?.host?.lowercased() ?? s
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        return host(a) == host(b)
    }
}
