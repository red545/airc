// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Live Captures (Arc's: "a captured part of a page stays live"; parity N03, docs/user/easels.md). A Capture block can
// keep where its picture came from: the page's address, the profile it was signed in with, the captured region in the
// page's own CSS pixels, and the page's viewport and zoom. Refresh takes the picture again from a page loaded offscreen
// in that profile; a Live block does it by itself when its Easel opens and every so often while it's shown. Detach
// forgets the source, and the block is a plain picture again.
//
// The source is an optional `live` key on the capture (format 1 stays readable; an older build keeps the key as it
// reads the block and shows the last picture).

/// Where a live Capture's picture comes from, and how it went last time.
public struct EaselLiveSource: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Refreshed when its Easel opens (if older than `EaselLivePolicy.staleAfter`) and while it's shown.
        case live
        /// Refreshed only when asked (Refresh, ⌘R on the Easel).
        case manual
    }

    /// How the last refresh went. The last good picture stays on the block whatever it says.
    public enum Status: String, Codable, Sendable {
        case ok
        /// The page asked to sign in (401/403, or it went to a sign-in page): "Sign in to refresh".
        case signedOut
        /// No network.
        case offline
        /// Anything else (an error page, a time-out, the region gone from the page); `message` says which.
        case failed
        /// The profile it was captured in is gone.
        case unavailable
    }

    /// Changes whenever the source is set again, so a refresh that started before can tell it's stale.
    public var id: String
    public var url: String
    /// The Airc profile (never a private window's: those have none).
    public var profileID: String
    /// The captured region in the page's CSS pixels, from the document's top left.
    public var rect: EaselRect
    /// Where the page was scrolled (CSS pixels), so fixed and sticky parts come out where they were.
    public var scrollX: Double
    public var scrollY: Double
    /// The page's layout viewport in CSS pixels: the offscreen page is laid out at this size.
    public var viewportWidth: Double
    public var viewportHeight: Double
    /// The page's zoom when captured (1: 100 %). The region is in CSS pixels, so it holds at any zoom.
    public var zoom: Double
    public var mode: Mode
    public var status: Status
    public var message: String?
    /// The last good picture's time.
    public var refreshedAt: Date?
    /// The last attempt's time, and how many failed in a row (back-off for automatic refreshes).
    public var attemptedAt: Date?
    public var failures: Int

    public init(id: String = newID(), url: String, profileID: String, rect: EaselRect, scrollX: Double = 0, scrollY: Double = 0,
                viewportWidth: Double, viewportHeight: Double, zoom: Double = 1, mode: Mode = .live, refreshedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.profileID = profileID
        self.rect = rect
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.zoom = zoom
        self.mode = mode
        status = .ok
        message = nil
        self.refreshedAt = refreshedAt
        attemptedAt = nil
        failures = 0
    }

    /// Pages a live Capture can come from: http and https only (never a note, a file, a private or internal page).
    public static func isLiveableURL(_ s: String?) -> Bool {
        guard let s, let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return false }
        return true
    }

    /// Everything a refresh needs is there and sane (a damaged or hand-edited file can say anything).
    public var isValid: Bool {
        Self.isLiveableURL(url) && !profileID.isEmpty && rect.isFinite && rect.width >= 1 && rect.height >= 1
            && viewportWidth.isFinite && viewportHeight.isFinite && viewportWidth >= 1 && viewportHeight >= 1
            && viewportWidth <= 16384 && viewportHeight <= 16384 && zoom.isFinite && zoom > 0
            && scrollX.isFinite && scrollY.isFinite
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, profileID, rect, scrollX, scrollY, viewportWidth, viewportHeight, zoom, mode, status, message, refreshedAt, attemptedAt, failures
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? newID()
        url = try c.decode(String.self, forKey: .url)
        profileID = try c.decode(String.self, forKey: .profileID)
        rect = try c.decode(EaselRect.self, forKey: .rect)
        scrollX = (try? c.decodeIfPresent(Double.self, forKey: .scrollX)) ?? 0
        scrollY = (try? c.decodeIfPresent(Double.self, forKey: .scrollY)) ?? 0
        viewportWidth = try c.decode(Double.self, forKey: .viewportWidth)
        viewportHeight = try c.decode(Double.self, forKey: .viewportHeight)
        zoom = (try? c.decodeIfPresent(Double.self, forKey: .zoom)) ?? 1
        // A mode or status a newer build added reads as the safest one this build knows.
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .manual
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .ok
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        refreshedAt = try? c.decodeIfPresent(Date.self, forKey: .refreshedAt)
        attemptedAt = try? c.decodeIfPresent(Date.self, forKey: .attemptedAt)
        failures = max(0, (try? c.decodeIfPresent(Int.self, forKey: .failures)) ?? 0)
    }

    /// What the block's chip says beside "Live" ("Sign in to refresh"), or nil when the last refresh worked.
    public var problem: String? {
        switch status {
        case .ok: nil
        case .signedOut: "Sign in to refresh"
        case .offline: "Offline"
        case .failed: message ?? "Couldn't refresh"
        case .unavailable: "Profile is gone"
        }
    }
}

/// When refreshes happen by themselves.
public enum EaselLivePolicy {
    /// A Live block older than this refreshes when its Easel opens, and while the Easel is shown.
    public static let staleAfter: TimeInterval = 15 * 60
    /// Back-off after failures in a row: `staleAfter` × 2^(failures − 1), at most a day.
    public static let maximumBackoff: TimeInterval = 24 * 3600
    /// One refresh gives up after this long.
    public static let timeout: TimeInterval = 20
    /// Refreshes at once, app-wide.
    public static let concurrency = 2

    public static func backoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(maximumBackoff, staleAfter * pow(2, Double(min(failures, 16) - 1)))
    }

    /// Whether `s` should refresh by itself at `now`. Manual sources never do; a profile that's gone waits for a person.
    public static func isDue(_ s: EaselLiveSource, now: Date) -> Bool {
        guard s.mode == .live, s.isValid, s.status != .unavailable else { return false }
        if s.failures > 0, let a = s.attemptedAt { return now.timeIntervalSince(a) >= backoff(failures: s.failures) }
        guard let r = s.refreshedAt else { return true }
        return now.timeIntervalSince(r) >= staleAfter
    }

    /// "Updated 5 min ago" (the block's menu).
    public static func age(_ s: EaselLiveSource, now: Date) -> String {
        guard let r = s.refreshedAt else { return "Not updated yet" }
        let t = max(0, now.timeIntervalSince(r))
        switch t {
        case ..<60: return "Updated just now"
        case ..<3600: return "Updated \(Int(t / 60)) min ago"
        case ..<86400: let h = Int(t / 3600); return "Updated \(h) hour\(h == 1 ? "" : "s") ago"
        default: let d = Int(t / 86400); return "Updated \(d) day\(d == 1 ? "" : "s") ago"
        }
    }
}

/// The arithmetic between the page's CSS pixels, the view's points and a picture's pixels.
public enum EaselLiveGeometry {
    /// What the page said about itself when captured (its script reads these).
    public struct PageMetrics: Hashable, Sendable {
        public var scrollX: Double
        public var scrollY: Double
        /// Layout viewport, CSS pixels.
        public var innerWidth: Double
        public var innerHeight: Double
        /// Pinch zoom (visualViewport.scale) and where the visual viewport is in the document.
        public var visualScale: Double
        public var visualLeft: Double
        public var visualTop: Double

        public init(scrollX: Double, scrollY: Double, innerWidth: Double, innerHeight: Double, visualScale: Double = 1,
                    visualLeft: Double? = nil, visualTop: Double? = nil) {
            self.scrollX = scrollX
            self.scrollY = scrollY
            self.innerWidth = innerWidth
            self.innerHeight = innerHeight
            self.visualScale = visualScale > 0 && visualScale.isFinite ? visualScale : 1
            self.visualLeft = visualLeft ?? scrollX
            self.visualTop = visualTop ?? scrollY
        }

        /// From the page script's answer `[scrollX, scrollY, innerWidth, innerHeight, vvScale, vvPageLeft, vvPageTop]`.
        public init?(_ any: Any?) {
            var nums: [Double] = []
            if let a = any as? [Any] { nums = a.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) } }
            else if let s = any as? String, let d = s.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [Any] {
                nums = a.compactMap { ($0 as? NSNumber)?.doubleValue }
            }
            guard nums.count >= 4, nums.allSatisfy(\.isFinite), nums[2] >= 1, nums[3] >= 1 else { return nil }
            self.init(scrollX: nums[0], scrollY: nums[1], innerWidth: nums[2], innerHeight: nums[3],
                      visualScale: nums.count > 4 ? nums[4] : 1, visualLeft: nums.count > 5 ? nums[5] : nil, visualTop: nums.count > 6 ? nums[6] : nil)
        }

        /// The script both engines run (in the page's world): the numbers above, as a JSON string.
        public static let script = "JSON.stringify([scrollX, scrollY, innerWidth, innerHeight, (window.visualViewport||{}).scale||1, (window.visualViewport||{}).pageLeft||scrollX, (window.visualViewport||{}).pageTop||scrollY])"
    }

    /// The page's zoom from the view's width in points and its layout width in CSS pixels.
    public static func zoom(viewWidth: Double, innerWidth: Double) -> Double {
        guard viewWidth > 0, innerWidth > 0 else { return 1 }
        let z = viewWidth / innerWidth
        // Engines round the layout width: snap to a zoom step within half a percent.
        for step in [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5] where abs(z - step) / step < 0.005 { return step }
        return z
    }

    /// A selection in the page view's points (top left origin) as a source: the region in document CSS pixels.
    public static func source(selection: EaselRect, viewWidth: Double, page: PageMetrics, url: String, profileID: String,
                              mode: EaselLiveSource.Mode = .live, at date: Date = Date()) -> EaselLiveSource? {
        guard EaselLiveSource.isLiveableURL(url), !profileID.isEmpty, selection.isFinite, selection.width >= 1, selection.height >= 1 else { return nil }
        let z = zoom(viewWidth: viewWidth, innerWidth: page.innerWidth)
        let k = z * page.visualScale
        let rect = EaselRect(x: page.visualLeft + selection.x / k, y: page.visualTop + selection.y / k,
                             width: selection.width / k, height: selection.height / k)
        let s = EaselLiveSource(url: url, profileID: profileID, rect: rect, scrollX: page.scrollX, scrollY: page.scrollY,
                                viewportWidth: page.innerWidth, viewportHeight: page.innerHeight, zoom: z, mode: mode, refreshedAt: date)
        return s.isValid ? s : nil
    }

    /// Where the region is in a picture of the whole viewport (`pixelWidth` × `pixelHeight` pixels, the page scrolled to
    /// `page`'s offsets), in pixels from the picture's top left; nil when no part of it is in the picture. A region
    /// partly off the viewport is cut to what's there.
    public static func crop(_ s: EaselLiveSource, pixelWidth: Double, pixelHeight: Double, page: PageMetrics) -> EaselRect? {
        guard pixelWidth >= 1, pixelHeight >= 1, page.innerWidth >= 1 else { return nil }
        let k = pixelWidth / page.innerWidth * page.visualScale
        let x0 = (s.rect.x - page.visualLeft) * k, y0 = (s.rect.y - page.visualTop) * k
        let x1 = x0 + s.rect.width * k, y1 = y0 + s.rect.height * k
        let cx0 = max(0, x0), cy0 = max(0, y0), cx1 = min(pixelWidth, x1), cy1 = min(pixelHeight, y1)
        // Less than a quarter of it on the page: it isn't there any more.
        guard cx1 - cx0 >= 1, cy1 - cy0 >= 1, (cx1 - cx0) * (cy1 - cy0) >= 0.25 * (x1 - x0) * (y1 - y0) else { return nil }
        return EaselRect(x: cx0.rounded(), y: cy0.rounded(), width: (cx1 - cx0).rounded(), height: (cy1 - cy0).rounded())
    }

    /// Where to scroll so the region is in view: the captured scroll when it shows the region (fixed and sticky parts
    /// as they were), else the region's top left with a little room.
    public static func scrollTarget(_ s: EaselLiveSource) -> (x: Double, y: Double) {
        let inX = s.rect.x >= s.scrollX && s.rect.maxX <= s.scrollX + s.viewportWidth
        let inY = s.rect.y >= s.scrollY && s.rect.maxY <= s.scrollY + s.viewportHeight
        if inX && inY { return (s.scrollX, s.scrollY) }
        return (inX ? s.scrollX : max(0, s.rect.x - 16), inY ? s.scrollY : max(0, s.rect.y - 16))
    }

    /// A page the person landed on instead (signed out): the site changed, or a sign-in path appeared.
    public static func looksSignedOut(captured: String, landed: String?, httpStatus: Int?) -> Bool {
        if let st = httpStatus, st == 401 || st == 403 { return true }
        guard let landed, let a = URL(string: captured), let b = URL(string: landed) else { return false }
        // The registrable domain by the Public Suffix List ("a.co.uk" and "b.co.uk" are two sites), as Peek decides it.
        func site(_ h: String?) -> String { h.flatMap { BoostDomain.key(forHost: $0) } ?? "" }
        let signIn = #"(^|/)(login|log-in|signin|sign-in|sign_in|auth|sso|oauth|accounts?/login|session/new|users/sign_in)(/|$|\?)"#
        let wasSignIn = a.path.lowercased().range(of: signIn, options: .regularExpression) != nil
        let isSignIn = b.path.lowercased().range(of: signIn, options: .regularExpression) != nil
        if isSignIn && !wasSignIn { return true }
        return site(a.host) != site(b.host) && (isSignIn || b.host?.lowercased().hasPrefix("accounts.") == true || b.host?.lowercased().hasPrefix("login.") == true)
    }
}

/// How one refresh ended.
public enum EaselLiveOutcome: Hashable, Sendable {
    /// A new picture (an asset already in the Easel's folder) of this many pixels.
    case picture(asset: String, pixelWidth: Double, pixelHeight: Double)
    case signedOut
    case offline
    case failed(String)
    case unavailable
}

extension EaselCapture {
    /// The capture with a refresh's outcome: a new picture and "ok", or the last picture kept with what went wrong.
    public func applying(_ o: EaselLiveOutcome, at now: Date) -> EaselCapture {
        guard var s = live else { return self }
        var c = self
        s.attemptedAt = now
        switch o {
        case .picture(let asset, let w, let h):
            c.asset = asset
            c.pixelWidth = w
            c.pixelHeight = h
            c.capturedAt = now
            s.status = .ok
            s.message = nil
            s.refreshedAt = now
            s.failures = 0
        case .signedOut: s.status = .signedOut; s.message = nil; s.failures += 1
        case .offline: s.status = .offline; s.message = nil; s.failures += 1
        case .failed(let m): s.status = .failed; s.message = m; s.failures += 1
        case .unavailable: s.status = .unavailable; s.message = nil; s.failures += 1
        }
        c.live = s
        return c
    }
}

extension EaselDocument {
    /// The blocks with a live source (any mode).
    public var liveBlocks: [EaselBlock] {
        blocks.filter { if case .capture(let c) = $0.content { return c.live != nil }; return false }
    }

    /// The live source of block `id`, if it has one.
    public func liveSource(_ id: String) -> EaselLiveSource? {
        if case .capture(let c)? = block(id)?.content { return c.live }
        return nil
    }

    /// A refresh of block `blockID` that started for source `sourceID` ended with `o`. False (nothing changed) when
    /// the block is gone, was detached, or its source was set again since: a late answer never lands on the wrong one.
    @discardableResult
    public mutating func applyLive(_ o: EaselLiveOutcome, blockID: String, sourceID: String, at now: Date = Date()) -> Bool {
        guard let i = index(blockID), case .capture(let c) = blocks[i].content, c.live?.id == sourceID else { return false }
        blocks[i].content = .capture(c.applying(o, at: now))
        return true
    }

    /// Sets (or with nil, removes: Detach) block `id`'s live source. False when it isn't a Capture.
    @discardableResult
    public mutating func setLive(_ s: EaselLiveSource?, for id: String) -> Bool {
        guard let i = index(id), case .capture(var c) = blocks[i].content else { return false }
        if let s, !s.isValid { return false }
        c.live = s
        blocks[i].content = .capture(c)
        return true
    }

    /// Live ↔ Manual for block `id`.
    @discardableResult
    public mutating func setLiveMode(_ m: EaselLiveSource.Mode, for id: String) -> Bool {
        guard var s = liveSource(id) else { return false }
        s.mode = m
        return setLive(s, for: id)
    }

    /// The Live blocks due for an automatic refresh at `now`.
    public func dueLiveBlocks(now: Date) -> [String] {
        liveBlocks.filter { b in liveSource(b.id).map { EaselLivePolicy.isDue($0, now: now) } ?? false }.map(\.id)
    }
}

extension EaselHistory {
    /// A source that arrived just after its block was added (the page answers where it was a moment later): the steps
    /// that hold block `id` without a source take it, so undoing and redoing the Add keeps the block live.
    public mutating func attachLive(_ live: EaselLiveSource, to id: String) {
        func patched(_ b: EaselBlock?) -> EaselBlock? {
            guard var b, b.id == id, case .capture(var c) = b.content, c.live == nil else { return b }
            c.live = live
            b.content = .capture(c)
            return b
        }
        for stack in [\EaselHistory.undoStack, \EaselHistory.redoStack] {
            for i in self[keyPath: stack].indices {
                for j in self[keyPath: stack][i].changes.indices where self[keyPath: stack][i].changes[j].id == id {
                    self[keyPath: stack][i].changes[j].before = patched(self[keyPath: stack][i].changes[j].before)
                    self[keyPath: stack][i].changes[j].after = patched(self[keyPath: stack][i].changes[j].after)
                }
            }
        }
    }

    /// A refresh isn't an undo step, so the steps that hold block `id` take its new picture and state: undoing an
    /// earlier move never brings an old picture back. Only the capture's picture and live state change in them (a step
    /// that removed the block, or detached it, keeps what it says).
    public mutating func carryLive(of block: EaselBlock) {
        guard case .capture(let now) = block.content, let live = now.live else { return }
        func patched(_ b: EaselBlock?) -> EaselBlock? {
            guard var b, b.id == block.id, case .capture(var c) = b.content, c.live?.id == live.id else { return b }
            c.asset = now.asset
            c.pixelWidth = now.pixelWidth
            c.pixelHeight = now.pixelHeight
            c.capturedAt = now.capturedAt
            var l = live
            l.mode = c.live?.mode ?? live.mode   // the step's own mode change stays its own
            c.live = l
            b.content = .capture(c)
            return b
        }
        for stack in [\EaselHistory.undoStack, \EaselHistory.redoStack] {
            for i in self[keyPath: stack].indices {
                for j in self[keyPath: stack][i].changes.indices where self[keyPath: stack][i].changes[j].id == block.id {
                    self[keyPath: stack][i].changes[j].before = patched(self[keyPath: stack][i].changes[j].before)
                    self[keyPath: stack][i].changes[j].after = patched(self[keyPath: stack][i].changes[j].after)
                }
            }
        }
    }
}
